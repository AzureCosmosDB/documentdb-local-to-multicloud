# DocumentDB Multi-Cloud Monitor

The existing Topology, Bookings, Vector Search and Load tabs work with AKS + EKS,
two regional AKS members, or all three. The header's existing theme toggle switches
between a white/slate developer console with blue accents and horizontal topology
rows, and a navy infrastructure console with teal accents and cluster panels.
Both themes cover all four tabs, including responsive layouts and keyboard focus.
The controls and demo workflow are unchanged.

## Run

Use Node.js 24 LTS, kubectl and the operator 1.0.0 `kubectl documentdb` plugin.
The [deployment guide](../../infra/multi-cloud/README.md) covers prerequisites.

```powershell
npm ci --prefix app\monitor-app
.\start.ps1

# Azure-only, after deploying the regional topology:
.\start.ps1 -MemberContexts azure-documentdb,azure-documentdb-secondary

# All three:
.\start.ps1 -MemberContexts azure-documentdb,azure-documentdb-secondary,aws-documentdb
```

`-NoGrafana` skips Grafana discovery/tabs; `-NoBrowser` opens no browser tabs.
`-HubContext` overrides the Fleet context. Existing environment settings are
preserved. When explicit contexts are absent, the launcher uses the deployment
flags `INCLUDE_EKS`, `INCLUDE_AKS_REPLICA`, `INCLUDE_GKE` and member-name settings.
It discovers Grafana addresses independently in each member's `monitoring`
namespace. No IP addresses or passwords are embedded in the launcher.

For a manual launch:

```powershell
$env:DDB_NAMESPACE = "documentdb-preview-ns"
$env:DDB_RESOURCE = "documentdb-preview"
$env:DDB_HUB_CONTEXT = "hub"
$env:DDB_MEMBER_CONTEXTS = "azure-documentdb,azure-documentdb-secondary"
node app\monitor-app\server.js
```

The server binds to `127.0.0.1:5174` by default. It runs with the presenter's
Kubernetes permissions and is not an authenticated public service.

| Variable | Meaning |
|---|---|
| `PORT` | Local server port, default 5174 |
| `DDB_NAMESPACE`, `DDB_RESOURCE`, `DDB_HUB_CONTEXT` | Required when starting Node directly |
| `DDB_MEMBER_CONTEXTS` | Required comma-separated **member names/context aliases**, not provider names |
| `DDB_GATEWAY_USER` | Mongo gateway user, default `docdb` |
| `DDB_DEMO_DATABASE` | Database, default `bookingsdb` |
| `KUBECTL_BIN` | kubectl executable, default `kubectl` |
| `LOCAL_MONGODB_URI` | Local Docker connection for Vector Search |
| `DDB_LEGACY_RECOVERY` | Default false; explicitly opt into old preview recovery only |

## Data path and safety

Bookings and Load use the MongoDB driver and persistent port-forwards to
`documentdb-service-<resource>:10260`. The current primary comes from the hub CR,
cached for two seconds and invalidated on promotion; hub failures are not hidden
by serving an old cached primary. Each replica has a separate connection pool
and measured booking-replication timing. Vector Search remains local and uses
the existing embedding configuration from the ignored `.env`.

CNPG discovery is scoped by DocumentDB ownership (single-shard demo only).
Promotion checks every active member, its current leader and upstream source,
and WAL streaming. The existing button invokes the supported plugin without
`--failover` and waits for completion. Failures are shown in the operation log;
the monitor never treats healthy pod counts alone as replication proof.
The process serializes topology-changing requests; run only one monitor for
a given topology. No promise of zero data loss is made.

Operator 1.0.0 clears stale promotion tokens itself. The monitor no longer
patches durability settings or clears tokens automatically after promotion.
The **Rebuild replica** control is still destructive and requires confirmation.
It only accepts an active non-primary member with a healthy primary to rebuild
from. Monitor status and upstream recovery guidance remain authoritative.

There is no verified evidence that the old certificate-rebuild workaround is
necessary on GA. It and the legacy manual token controls are retained only
behind `DDB_LEGACY_RECOVERY=true` for preview troubleshooting, not silently run
against GA. `fix-rebuild.bat` / `scripts/fix-rebuild-certs.ps1` are legacy manual
tools, not routine GA setup steps.

The topology's WAL SQL and its write probe are real database operations.
Do not open the production server against live contexts merely to preview CSS.

## Local regression checks

```powershell
npm test --prefix app\monitor-app
```

These use Node's test runner, mocked promotion commands, an ephemeral local
Express server and Bash's offline `--render` path. They do not authenticate,
provision, promote or modify Azure/AWS/Kubernetes resources.
Cloud replication, restart behavior, actual metrics and data migration still
require an explicitly authorized integration rehearsal.
