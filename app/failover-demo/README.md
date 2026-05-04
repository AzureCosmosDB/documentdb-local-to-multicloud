# DocumentDB Cross-Cloud Failover Demo

Live-presentable demo app for the **Techorama Belgium 2026** session
*"From Localhost to Multi-Cloud: Building Production-Ready Apps with DocumentDB"*
(Mark Brown, PM — Cosmos DB).

A web app with two cluster panels (AKS eastus2 / EKS us-west-2), a continuous
writer loop, live document counts and replication-lag indicators, and a **🔴 BIG
RED BUTTON** that triggers `kubectl documentdb promote` to fail over from one
cloud to the other while the audience watches the writes flip in real time.

The app writes to its own collection (`demodb.failover_demo_events`) and does
not depend on the `demodb.stays` search dataset.

## Architecture

- **Server** (`server/`): Node 20 + TypeScript + Express + `ws`. Maintains a
  writer loop, polls both clusters every 500 ms, and orchestrates failover by
  spawning `kubectl documentdb promote …`.
- **Web** (`web/`): Vite + React 18 + TypeScript. Single page, two cluster
  panels, control bar, big red button, event log. WebSocket-driven (1 Hz state
  + push events).

## Prerequisites

1. **Node 20+** and **npm 10+**
2. **kubectl** with both cluster contexts already configured (defaults expected:
   `azure-documentdb`, `aws-documentdb`, `hub`). The
   `kubectl-documentdb` plugin from
   [microsoft/documentdb-kubernetes-operator](https://github.com/microsoft/documentdb-kubernetes-operator)
   must be on your `PATH`. Verify with: `kubectl documentdb --help`.
3. **A running multi-cloud DocumentDB deployment** from `infra/multi-cloud/`
   (built by the `multicloud-rebuild` agent). For local development you can
   skip this and use the smoke-test mode below.
4. Either:
   - **Port-forwards** in two terminals (recommended for the live conference
     demo — more reliable on conference Wi-Fi than EKS LoadBalancers):
     ```bash
     kubectl --context azure-documentdb -n documentdb-preview-ns \
       port-forward svc/documentdb-service-azure-documentdb 27018:10260
     kubectl --context aws-documentdb -n documentdb-preview-ns \
       port-forward svc/documentdb-service-aws-documentdb 27019:10260
     ```
   - **OR** direct LoadBalancer/SRV URIs in `clusters.json`.

## Setup

```bash
cd app/failover-demo
npm install                            # installs root + workspaces
cp .env.example .env                   # optional: env-var overrides
cp clusters.example.json clusters.json # then edit URIs
```

Edit `clusters.json`:

- Replace `CHANGE_ME` with the `docdb` user password.
- If using port-forwards, leave hostnames as `localhost:27018` / `localhost:27019`.
- If using LoadBalancer URIs, paste the full `mongodb+srv://…` (or
  `mongodb://host:10260/…`) string.
- Confirm `kubeContext` matches the contexts in `kubectl config get-contexts`.
- Confirm `documentdbResource` matches `kubectl --context hub get documentdb -A`.

## Run

```bash
npm run dev
```

This starts:

- The server on **http://localhost:4000** (REST + WebSocket at `/ws`)
- Vite on **http://localhost:5173** with proxies for `/api` and `/ws`

Open <http://localhost:5173>.

## Local smoke test (no clusters required)

The smoke test points **both** cluster slots at the local Docker DocumentDB
(`docker compose up -d` in the repo root) and runs the writer loop for 10s,
verifying the server starts, the WS broadcaster works, the poller reports doc
counts, and writes succeed.

```bash
# from repo root, ensure local DocumentDB is up:
docker compose up -d documentdb

cd app/failover-demo
npm install
npm run smoke   # runs scripts/smoke-test.sh
```

Expected: `[smoke] PASS — N docs in failover_demo_events`.

> The failover button will fail in smoke mode (no real `kubectl` contexts) — the
> smoke test only validates server bootstrapping, polling, and writes.

## Demo flow (live, on stage)

> Mark — this is the order to walk through on stage. Practice once before
> Antwerp; the failover takes ~30–60 s of dead air, so prepare narration.

1. Open <http://localhost:5173> in the projector browser. Confirm both panels
   show **AKS = PRIMARY (green)** and **EKS = REPLICA (blue)**, both with
   green reachability dots.
2. Verify auto-insert is **ON** (default 2 Hz). Both doc counts should tick up
   together — AKS first, EKS following with a small replication lag visible on
   the EKS panel.
3. Talk for ~30 s about the architecture: AKS Fleet propagates the DocumentDB
   CR, CNPG streams WAL across the Istio mesh, both clusters share a root CA.
   The audience watches counters tick during this.
4. Point out the **Replication lag** number on the EKS panel (typically
   single-digit ms within the same lab; tens to hundreds across regions).
5. Click the **🔴 FAILOVER AKS → EKS** button. Read the modal aloud. Click
   **Failover now** (or wait for the 5s cancel countdown to elapse).
6. The button becomes a progress strip: **PROMOTING → RECONFIGURING → ROUTING
   → COMPLETE**. The streamed `kubectl` log appears under it. Narrate the
   phases — the operator is demoting the AKS primary, promoting the EKS
   replica, then the app re-routes its writer.
7. After ~30–45 s the strip turns green (**COMPLETE**). Now:
   - **EKS** panel turns green: **PRIMARY**.
   - **AKS** panel turns blue: **REPLICA** (or amber **READ-ONLY** while the
     operator finishes re-bootstrapping).
   - Doc counts continue ticking — **on EKS first now**.
8. Optional callouts:
   - The writer never stopped — only the *direction* changed.
   - Open the event log at the bottom: `failover` event, then `insert →ks`
     events resume.

## Failback (open question — verify live)

Failing back is "the same button in reverse" *if* the demoted AKS member has
finished re-bootstrapping as a replica. Two scenarios:

- **If the operator auto-rewinds** the demoted primary via `pg_rewind`/CNPG
  re-bootstrap → AKS will appear as REPLICA within ~1–2 minutes after promote.
  At that point click **🔴 FAILOVER EKS → AKS** to restore.
- **If the operator does not auto-rewind** (TBD — needs verification against
  the live multicloud rebuild) → you will need to manually re-bootstrap the AKS
  member before failback. Mark: confirm during dry-run.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Both panels red **UNREACHABLE** immediately on startup | URIs wrong / port-forwards not running | `kubectl get pods -n documentdb-preview-ns`, restart port-forwards |
| AKS green, EKS red | Only one port-forward running | Start the second `kubectl port-forward` |
| `auth failed` in event log | `clusters.json` password wrong | Re-fetch: `kubectl --context hub get secret documentdb-credentials -n documentdb-preview-ns -o jsonpath='{.data.password}' \| base64 -d` |
| Failover stuck at PROMOTING | Plugin not on PATH or wrong contexts | `kubectl documentdb --help`; check `clusters.json` `kubeContext` values |
| Failover succeeds but writes still go to old primary | Writer didn't get re-routed | Check server log; the writer reads `state.primary` each tick — restart server |
| Replication lag huge or growing | Cross-cloud network issue or replica behind | Check Istio east-west gateway, CNPG status: `kubectl --context aws-documentdb -n documentdb-preview-ns get cluster` |
| 🔴 button greyed out | Failover already in progress, or `state.failover.active=true` from a prior run that didn't finish | Restart server (state is in-memory) |

## Files

```
app/failover-demo/
├── README.md                <- this file
├── package.json             <- npm workspaces (server, web)
├── .env.example
├── clusters.example.json
├── scripts/
│   └── smoke-test.sh        <- 10s local smoke test (uses docker compose docdb)
├── server/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts         <- express + ws bootstrap
│       ├── config.ts        <- env + clusters.json loader
│       ├── db.ts            <- mongo clients
│       ├── state.ts         <- in-memory state machine
│       ├── poller.ts        <- 500ms cluster polling
│       ├── writer.ts        <- write loop with rate control + retry
│       ├── failover.ts      <- kubectl documentdb promote orchestration
│       ├── ws.ts            <- ws broadcaster (1Hz state + events)
│       └── types.ts
└── web/
    ├── package.json
    ├── vite.config.ts
    ├── index.html
    ├── tsconfig.json
    └── src/
        ├── main.tsx
        ├── App.tsx
        ├── styles.css
        ├── types.ts
        ├── hooks/useWsState.ts
        └── components/
            ├── ClusterPanel.tsx
            ├── FailoverButton.tsx
            ├── ControlBar.tsx
            └── EventLog.tsx
```

## What the failover command actually runs

The orchestrator spawns:

```
kubectl documentdb promote \
  --documentdb <documentdbResource> \
  --namespace  <namespace> \
  --hub-context <hubContext> \
  --target-cluster <toCluster.kubeContext> \
  --cluster-context <toCluster.kubeContext>
```

(Confirmed against the upstream
[`documentdb-playground/multi-cloud-deployment` README](https://github.com/microsoft/documentdb-kubernetes-operator/tree/main/documentdb-playground/multi-cloud-deployment#failover-operations).)

If the plugin is not installed or the command fails, the orchestrator falls
back to a CRD patch:

```
kubectl --context <hubContext> patch documentdb <documentdbResource> \
  -n <namespace> --type merge \
  -p '{"spec":{"failover":{"targetMember":"<aks|eks>"}}}'
```

The patch path is a **best-effort fallback** — confirm the CRD actually
supports `spec.failover.targetMember` against the deployed operator version.
