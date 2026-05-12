# DocumentDB Multi-Cloud Monitor

Live monitoring + one-click failover dashboard for multi-cloud DocumentDB.

## What it does

- Polls `kubectl --context hub` for the DocumentDB CR
- For each member cluster, fetches the CNPG cluster CR (role, phase, pods, LB)
- For the primary, runs `pg_stat_replication` to show per-replica write/flush/replay lag
- "Promote to primary" button shells out to `kubectl documentdb promote`
- "Clear stale token" button (only shown on stuck clusters) does the patch fix
- **Bookings tab** — direct Postgres reads/writes against the primary via the `pg` driver, with primary-then-replica refresh after each mutation so you can see physical replication catch up in real time

## Run

The easiest way is the repo-root launcher, which sets env vars, opens the UI,
opens both Grafana tabs, and starts the server in one shot:

```powershell
# From the repo root (documentdb-local-to-multicloud)
.\start.ps1
```

First-time setup (once per clone):

```powershell
cd app\monitor-app
npm install
```

Flags on `start.ps1`:

- `-NoGrafana` — skip the two Grafana tabs
- `-NoBrowser` — start the server without opening any tabs

If you'd rather run the monitor by hand (no auto-opened tabs, no Grafana):

```powershell
cd app\monitor-app
$env:PORT = "5174"
$env:DDB_HUB_CONTEXT = "hub"
$env:DDB_MEMBER_CONTEXTS = "azure-documentdb,aws-documentdb"
node server.js
# open http://localhost:5174
```

Dependencies: `express`, `pg` (auto-installed by `npm install`).

## Configuration (env vars)

| Var | Default |
|---|---|
| `PORT` | `5174` |
| `DDB_NAMESPACE` | `documentdb-preview-ns` |
| `DDB_RESOURCE` | `documentdb-preview` |
| `DDB_HUB_CONTEXT` | `hub` |
| `DDB_MEMBER_CONTEXTS` | `azure-documentdb,aws-documentdb` |
| `KUBECTL_BIN` | `kubectl` |

## Demo notes

- Clawpilot theme (auto light/dark via `prefers-color-scheme`, manual toggle in header)
- Topology tab: status auto-refreshes every 5 seconds (toggle off if presenting and you want a stable frame)
- Bookings tab: **event-driven** — replicas are re-fetched only after a mutation lands on the primary, so you never see "replica before primary" rendering glitches
- Promote button streams `kubectl documentdb promote` output to the on-screen log
- The "Clear stale token" button only appears when phase reason mentions "promotion token" — implements the gotcha fix from the workstream README

## How this app talks to Postgres (and how a real deployment would do it)

This monitor-app does NOT use a production-grade data path — it's optimized to run from a presenter's laptop with no infra changes. The patterns split into two buckets:

### Real patterns (use as-is)

- **`pg` driver + connection pool to the CNPG `<cluster>-rw` service.** This is the recommended way for any app to talk to a CNPG cluster. The `-rw` service auto-routes to the current primary instance.
- **Auth via the `<cluster>-app` Secret.** CNPG provisions a non-superuser `app` role for application data. Real apps mount that Secret as env vars (`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`) on the Pod.
- **Cache "which cluster is primary" and invalidate on failover.** Asking the hub on every write is wasteful — checking once per minute (or eventing off the failover) is plenty.
- **Sequenced primary-then-replica refresh** in the UI is the correct way to render reads after writes against an async-replica system. Otherwise the replica can render before the primary commits and look "wrong".
- **Application owns its tables.** Run DDL as the `app` user (or transfer ownership) so `TRUNCATE ... RESTART IDENTITY` and other owner-required ops work. We retrofit ownership with `ALTER TABLE bookings OWNER TO app; ALTER SEQUENCE bookings_id_seq OWNER TO app;`.

### Demo-only shortcuts (don't ship this)

- **`kubectl port-forward` from a laptop.** We tunnel through the K8s API server because the monitor-app runs outside both clusters (you don't want Postgres on a public LoadBalancer, and the presenter is on a hotel Wi-Fi). Each tunnel adds K8s-API hops and a single SPDY pipe — fine for one demo, wrong for production.
- **`discoverClusterCreds()` runtime kubectl-secret reads.** A real app mounts the secret directly. We do it at runtime because the monitor-app needs credentials for both clusters and isn't deployed in either of them.

### What a production deployment looks like

```
┌─────────────────────────┐
│  App / API server       │  ← runs as a Deployment in one of the member clusters
│  (in-cluster Pod)       │     (or in a peered VNet/VPC)
│                         │
│  Pool({                 │
│    host: '<cluster>-rw  │
│      .documentdb-preview│
│      -ns.svc.cluster    │
│      .local',           │
│    port: 5432,          │
│    user: env.PGUSER,    │  ← from <cluster>-app Secret mounted as env
│    password: env.PGPASS,│
│    database: 'app',     │
│  })                     │
└──────────┬──────────────┘
           │ direct TCP, no port-forward, no kubectl
           ▼
┌──────────────────────────────────────────┐
│ <cluster>-rw ClusterIP service (CNPG)    │
│ → routes to current primary instance     │
└──────────────────────────────────────────┘
```

For multi-cloud "which cluster is primary right now", a real deployment uses one of:
- **Global DNS** (Azure Traffic Manager / AWS Route 53) pointing at the active primary's external endpoint, flipped by the same automation that runs `kubectl documentdb promote`
- **A small router service near the hub** that the app queries (essentially what this monitor-app's primary-context cache does, but as a real service with proper SLAs)

If you ever want to turn this monitor-app into something customers could run, deleting `startPortForward()` / `discoverClusterCreds()` and replacing them with in-cluster service connections is roughly a 30-line change.

