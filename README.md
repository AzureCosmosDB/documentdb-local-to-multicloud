# DocumentDB: From Localhost to Multi-Cloud

Build, test, and scale across clouds with DocumentDB.

**Session:** From Localhost to Multi-Cloud: Building Production-Ready Apps with DocumentDB
**Event:** Techorama Belgium 2026 (May 11-13, Antwerp)
**Speaker:** Mark Brown

## What You'll See

- Spin up DocumentDB locally with Docker Compose in under 60 seconds
- Run semantic vector search on a real listings dataset (HNSW, 1536-dim, cosine)
- Deploy DocumentDB across **AKS + EKS** with cross-cloud WAL replication over an Istio mesh
- Drive a realistic travel-booking workload through a live web app
- Trigger a one-click cross-cloud failover and watch writes flip in real time
- Observe everything through Grafana dashboards on both clusters

## Quick start — local

```bash
git clone https://github.com/AzureCosmosDB/documentdb-local-to-multicloud.git
cd documentdb-local-to-multicloud
docker compose up -d
```

Docker Compose starts the `documentdb-local` container and auto-seeds the
`bookingsdb.listings` collection (1,000 listing documents with 1536-dim
`descriptionVector` fields) plus the vector + supporting indexes. Default
credentials: `demo` / `demo` on `localhost:27017`.

Connect with mongosh:

```bash
mongosh "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
```

Or use the **DocumentDB for VS Code** extension
([Marketplace](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-documentdb))
and point it at the same connection string.

## Prerequisites

- [Docker Desktop](https://www.docker.com/) — local stack
- [Visual Studio Code](https://code.visualstudio.com/) + [DocumentDB for VS Code](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-documentdb)
- [mongosh](https://www.mongodb.com/try/download/shell) — optional shell access
- [Node.js 20+](https://nodejs.org/) — for the monitor web app
- For the multi-cloud demo: Azure CLI, AWS CLI, `eksctl`, `kubectl`, `helm`, and a bash-capable shell (Git Bash on Windows)

See [SETUP.md](SETUP.md) for the full tooling matrix and cloud-account requirements.

## Repository structure

```
├── docker-compose.yml         # Local DocumentDB + auto-seeded listings
├── docker/seed/               # Seed container (loads data/listings_vectors.json)
├── data/                      # Demo datasets + load scripts
│   ├── listings_vectors.json  # 1K listings + 1536-dim embeddings
│   ├── load-data.sh           # Seed any DocumentDB target via $MONGODB_URI
│   └── load-data.ps1          # PowerShell equivalent
├── app/monitor-app/           # Live monitoring + failover web app (Node/Express)
├── infra/
│   ├── multi-cloud/           # Fleet hub + AKS + EKS + Istio + operator
│   ├── azure/                 # Standalone AKS deploy
│   └── aws/                   # Standalone EKS deploy
├── monitoring/                # kube-prometheus-stack Helm values + dashboards
├── demo/                      # Per-section runbooks (01-local … 06-multicloud)
├── docs/                      # Presenter runbook + technical notes
├── scripts/                   # Ad-hoc utilities (cert recovery, data load helpers)
├── start.ps1 / start.bat      # Launch monitor app + Grafana tabs
├── fix-rebuild.bat            # Manual recovery for operator cert-mismatch bug
└── SETUP.md                   # Full setup instructions
```

## The monitor app

The centerpiece of the live demo is the **Multi-Cloud Monitor** web app at
[`app/monitor-app/`](app/monitor-app/README.md). One launcher does everything:

```powershell
# From the repo root
.\start.ps1
```

This sets the env vars, launches the Node server on `http://localhost:5174`,
and opens the monitor UI plus both Grafana dashboards. Flags:
`-NoGrafana` skips the Grafana tabs, `-NoBrowser` skips opening tabs entirely.

The UI has four tabs:

| Tab | What it does |
| --- | --- |
| **Topology** | Live status of every cluster + per-replica WAL lag from `pg_stat_replication`. **Promote to primary** button triggers a one-click cross-cloud failover via `kubectl documentdb promote`. **Rebuild replica** wipes the replica's PVCs and rebuilds via `pg_basebackup` — with a background watcher that auto-recovers from a known cert-mismatch bug in the operator. |
| **Bookings** | Direct Mongo reads/writes against the **current primary** for `bookingsdb.bookings`. Each insert is followed by a wait-for-replication check so you can see the row appear on the replica with a measured lag. |
| **Vector Search** | `$vectorSearch` queries over `bookingsdb.listings` against the **local Docker** instance, using the HNSW index. Try queries like *"cozy mountain cabin with hot tub"*. |
| **Load** | A travel-booking workload generator: 80% browse / 15% detail / 4% insert / 1% confirm against the current primary. RPS slider with presets (idle / morning / peak / Black Friday) and an in-flight semaphore to keep client and server pools healthy. |

First-time setup of the monitor:

```powershell
cd app\monitor-app
npm install
```

## Multi-cloud deployment

> **Shell on Windows:** run the deploy/cleanup scripts from **Git Bash**.
> WSL has DNS issues with `login.microsoftonline.com`. PowerShell is fine for
> `docker compose`, `npm`, and the CLI tools above.

The talk uses the upstream `documentdb-playground/multi-cloud-deployment`
setup (vendored into [`infra/multi-cloud/`](infra/multi-cloud/README.md)),
which gives **real cross-cloud replication** instead of two unrelated
clusters:

- **AKS Fleet hub** in eastus2 (KubeFleet control plane for the DocumentDB CR)
- **AKS member** in eastus2 (DocumentDB primary by default)
- **EKS member** in us-west-2 (WAL replica)
- **Istio multi-cluster mesh** with shared root CA + east-west gateways for
  cross-cloud service discovery and mTLS-encrypted WAL replication
- **DocumentDB operator** on top of CloudNativePG, deployed to all members
- **kube-prometheus-stack** on each member, exposing Grafana with a shared
  `documentdb-failover` dashboard

```bash
# Sign in
az login
aws sso login

# Stand up the whole stack (Fleet hub + AKS + EKS + Istio + operator). ~25-35 min.
bash infra/multi-cloud/deploy.sh

# Deploy a DocumentDB cluster across the mesh.
bash infra/multi-cloud/deploy-documentdb.sh

# Tear it all down.
bash infra/multi-cloud/cleanup.sh -y --wait
```

See [`infra/multi-cloud/README.md`](infra/multi-cloud/README.md) for env-var
configuration (`INCLUDE_GKE=true` for a third leg, `PRIMARY_CLUSTER=...` to
start with EKS as primary, etc.).

The standalone single-cluster deploys are still in `infra/azure/` and
`infra/aws/` for anyone who wants the simpler "one cloud at a time" demo, but
the talk and the `demo/04-aks`, `demo/05-eks`, `demo/06-multicloud` runbooks
target the multi-cloud stack.

### Cost management

```bash
bash infra/scripts/start.sh                   # Start clusters for rehearsal
bash infra/scripts/stop.sh                    # Stop AKS / delete EKS to save costs
bash infra/multi-cloud/cleanup.sh -y --wait   # Full multi-cloud teardown
```

| Stack | Running | Stopped | Cleaned up |
| --- | --- | --- | --- |
| Multi-cloud (Fleet + AKS + EKS) | ~$13/day | n/a (tear down to save) | $0 |
| AKS standalone | ~$17/day | ~$0.03/day (disk) | $0 |
| EKS standalone | ~$5–8/day | n/a (must delete) | $0 |

## Loading data into a remote cluster

`data/load-data.sh` (or `load-data.ps1`) seeds any DocumentDB instance —
local, AKS, or EKS — given a `MONGODB_URI`. It loads
`data/listings_vectors.json` into `bookingsdb.listings`, creates the
`vectorSearchIndex` (HNSW, cosine, 1536-dim) and the supporting query indexes,
and is idempotent.

```bash
MONGODB_URI="mongodb://demo:demo@<lb-host>:10260/?tls=true&tlsAllowInvalidCertificates=true" \
  bash data/load-data.sh
```

## Demo runbooks

Section-by-section command sheets the speaker actually uses:

- [`demo/01-local`](demo/01-local) — Local Docker + VS Code extension
- [`demo/02-vector-search`](demo/02-vector-search) — Vector search walkthrough
- [`demo/03-cicd`](demo/03-cicd) — CI/CD against a DocumentDB emulator
- [`demo/04-aks`](demo/04-aks) — Single-cloud on AKS
- [`demo/05-eks`](demo/05-eks) — Single-cloud on EKS
- [`demo/06-multicloud`](demo/06-multicloud) — Cross-cloud failover

Presenter notes (timing, fallback plans, talk-track) live in
[`docs/presenter-runbook.md`](docs/presenter-runbook.md).

## License

MIT
