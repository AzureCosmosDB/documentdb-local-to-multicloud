# Setup Guide

Complete setup instructions for the "From Localhost to Multi-Cloud" demo environment.

> **Windows users**: the deploy/cleanup scripts under `infra/` are bash scripts. Run them from **Git Bash** (recommended) or **WSL**. PowerShell works for the `docker compose`, `python`, and `az`/`aws` CLI commands but cannot execute the `.sh` files directly.

## Prerequisites

### Current release baseline and migration

The demo pins DocumentDB operator/engine **1.0.0**, CNPG chart **0.28.3** (bundled
by the operator), cert-manager **1.21.3**, Istio **1.30.7**, and
kube-prometheus-stack **92.14.0**. Pins are centralized in `infra/versions.sh`.
The monitor uses Node.js **24 LTS**, Express **5.3.0**, MongoDB driver **7.7.0**,
and dotenv **18.0.8**, with committed npm lockfiles.

Use Kubernetes **1.35+ with ImageVolume enabled** on every data-bearing member.
The operator supports 1.33/1.34 only when the feature gate and runtime are
explicitly available; managed clusters may not expose that option. The Fleet
hub must meet the chart's 1.33+ floor. Do not select an unavailable version or
region merely to satisfy the pin. Verify provider availability/quotas first.

**Existing preview stacks are not automatically migrated.** Back up and verify
restores, then follow the
[operator 1.0 upgrade guide](https://documentdb.io/documentdb-kubernetes-operator/latest/preview/operations/upgrades/#upgrading-to-documentdb-10).
From 0.3.0, pin each cluster's engine and remove `schemaVersion: auto` before
upgrading the chart; the later extension/schema migration is irreversible.
From the RC engine, use a fresh GA cluster and a supported data migration.
The old copied `documentdb-base` operator placement is deliberately rejected by
the new deployment script. For that preview demo, create a **new dedicated RG
and stack**, migrate/verify data, and retire the old stack separately. Do not
delete the old placement or PVCs as an improvised in-place migration.

For a prepared non-legacy Helm installation, `ALLOW_OPERATOR_UPGRADE=true`
explicitly permits a chart version change; it is not a schema-migration tool.
`deploy-documentdb.sh` refuses an in-place engine-version change.

The local Docker image is pinned by tag and digest to `pg18-1.0.0`; do not reuse
an older PostgreSQL data directory without a supported data migration.
The ignored `data/listings_vectors.json` must be supplied locally for the seed
and vector-search demos; a fresh Git checkout does not contain that dataset.

### kubectl plugin

The plugin runs on the presenter's machine. Helm does **not** install a local
kubectl plugin. Build it from the same published operator release, using Git
and a compatible Go toolchain:

```bash
# Separate reference checkout; do not overwrite an existing operator checkout.
git clone --branch 1.0.0 --depth 1 \
  https://github.com/documentdb/documentdb-kubernetes-operator.git documentdb-operator-1.0.0
cd documentdb-operator-1.0.0/documentdb-kubectl-plugin
# Linux/macOS:
go build -o "$HOME/bin/kubectl-documentdb" .
# Windows Git Bash instead:
# go build -o "$HOME/bin/kubectl-documentdb.exe" .
kubectl documentdb promote --help
```

Create `$HOME/bin` first if needed and add it to PATH. The monitor uses planned
promotion without `--failover`. A failed/unreachable old primary requires the
upstream disaster-recovery procedure and a separate data-loss decision.

### Tools Required

| Tool | Purpose | Install |
| --- | --- | --- |
| Docker Desktop | Local DocumentDB | [docker.com](https://www.docker.com/) |
| VS Code | IDE + DocumentDB extension | [code.visualstudio.com](https://code.visualstudio.com/) |
| DocumentDB for VS Code | DB explorer, query editor, Index Advisor | [Marketplace](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-documentdb) |
| mongosh | MongoDB shell | [mongodb.com](https://www.mongodb.com/try/download/shell) |
| Git Bash (Windows) | bash for the deploy scripts | bundled with [Git for Windows](https://git-scm.com/download/win) |
| Azure CLI | AKS deployment | [Install](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| AWS CLI | EKS deployment | [Install](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| eksctl | EKS cluster management | [eksctl.io](https://eksctl.io/) |
| kubectl | Kubernetes CLI | [Install](https://kubernetes.io/docs/tasks/tools/) |
| Helm | K8s package manager | [helm.sh](https://helm.sh/docs/intro/install/) |

### Cloud Accounts

- **Azure subscription** with Contributor access
- **AWS account** with IAM permissions for EKS, EBS, and Load Balancer (only if EKS is enabled)

#### AWS authentication

If your AWS account uses **IAM Identity Center (SSO)** — typical for organizations — you cannot use `signin.aws.amazon.com/console` with a username/password. Instead:

1. Open the **AWS access portal URL** from your invitation email (looks like `https://d-xxxxxxxxxx.awsapps.com/start/`).
2. Sign in there with your SSO username + password.
3. Configure the CLI once with `aws configure sso` (or write `~/.aws/config` directly with `sso_start_url`, `sso_region`, `sso_account_id`, `sso_role_name`).
4. Then `aws sso login` triggers the browser flow and caches a token.

For plain IAM users, `aws configure` with an access key / secret key still works.

---

## Demo Environment Setup

### Phase 1: Local Development (no cloud needed)

```bash
# 1. Clone the repo
git clone https://github.com/AzureCosmosDB/documentdb-local-to-multicloud.git
cd documentdb-local-to-multicloud

# 2. Start DocumentDB + auto-load sample data (one command)
docker compose up -d

# 3. Verify it's running (wait ~30s for seed containers to finish)
docker compose ps
mongosh "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --eval "db.runCommand({ping:1})"

# 4. Create Python virtual environment and install dependencies
python -m venv .venv

# Activate (Windows PowerShell)
.\.venv\Scripts\Activate.ps1

# Activate (macOS/Linux)
# source .venv/bin/activate

pip install -r requirements.txt

# 5. (Data is auto-loaded by docker compose — ~1K listings with 1536-dim vectors)
# Verify:
mongosh "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --eval "use('bookingsdb'); db.listings.countDocuments()"

# 6. (Optional) Wipe indexes for Index Advisor demo
bash data/wipe-data.sh --indexes

# 7. (Optional) Wipe everything for full live demo
bash data/wipe-data.sh --all
```

**Connection string:** `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true`

> **Note:** docker-compose maps port 27017 (standard MongoDB port) externally to 10260 internally. The docdbdemo scripts use port 27017.

### Phase 2: VS Code Extension Setup

1. Install **DocumentDB for VS Code** extension
2. Click the DocumentDB icon in the sidebar
3. Click **+ New Connection**
4. Paste: `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256`
5. Test connection

### Phase 2b: Test Demo Scripts

```bash
# Index Advisor demo (interactive menu — shows COLLSCAN → IXSCAN transitions)
python scripts/query_examples.py

# Vector search demo (uses fake embeddings — no API key needed)
python scripts/vector_restaurants_demo.py --query "romantic Italian dinner" --mode compact --k 10
```

### Phase 3: Multi-cloud (AKS Fleet + AKS member + EKS member)

For two regional AKS members instead of EKS, export `INCLUDE_EKS=false`,
`INCLUDE_AKS_REPLICA=true`, and `AKS_REPLICA_REGION=<second-region>` before the
commands below, and skip `aws sso login`. Keep those settings for all scripts.
Leave EKS enabled for a three-member demo. See the
[complete topology configuration](infra/multi-cloud/README.md).

The talk uses the upstream `documentdb-playground/multi-cloud-deployment`
setup vendored into `infra/multi-cloud/`. It gives **real cross-cloud
replication** — one DocumentDB CR, propagated to both clusters by KubeFleet,
streaming WAL between Azure and AWS over an Istio multi-cluster mesh.

```bash
# Sign into both clouds
az login
aws sso login

# Stand up Fleet hub + AKS + EKS + Istio + operator (~25-35 min)
bash infra/multi-cloud/deploy.sh

# Deploy DocumentDB across the mesh (password retained in a Kubernetes Secret)
bash infra/multi-cloud/deploy-documentdb.sh
bash monitoring/deploy.sh
```

### Phase 3b: Load the demo dataset

Once the DocumentDB CR is healthy on both clouds, load the
`bookingsdb.listings` dataset onto the primary. **You do not need to know
which cloud is primary, the endpoint, or the password** — the script
discovers all of that from the Fleet hub:

```powershell
# From the repo root (Windows)
.\load-data.bat
```

```bash
# Or, if you're on Linux/WSL with the same kubectl contexts:
MONGODB_URI="mongodb://docdb:$(kubectl --context azure-documentdb -n documentdb-preview-ns get secret documentdb-credentials -o jsonpath='{.data.password}' | base64 -d)@127.0.0.1:57100/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" bash data/load-data.sh
# (the Windows wrapper above handles the port-forward automatically; on Linux,
#  run kubectl port-forward svc/documentdb-service-documentdb-preview 57100:10260 in another shell first)
```

The Windows wrapper:

1. Reads `spec.clusterReplication.primary` from the DocumentDB CR on the hub to find which cloud is currently primary
2. Pulls the `docdb` user password from the `documentdb-credentials` Secret
3. Sets up a temporary `kubectl port-forward` to that cluster's gateway service
4. Runs `mongoimport` (or falls back to `mongosh`) to load `data/listings_vectors.json`
5. Creates the cosmosSearch vector index + four query indexes
6. Tears down the port-forward

WAL replication carries the dataset to the replica cloud automatically — verify
with `kubectl --context <replica-context> exec ...` or via the monitor app's
Bookings tab.

This will:
1. Create Azure RG `docdb-multicloud-rg` in `eastus2`
2. Deploy AKS Fleet `aks-fleet-hub-fleet` + AKS member `azure-documentdb` via Bicep
3. Create EKS cluster `aws-documentdb` in `us-west-2` via eksctl, with EBS CSI driver and AWS LB controller
4. Join EKS to the AKS Fleet via the kubefleet bootstrap
5. Install cert-manager on every cluster
6. Install pinned Istio Helm charts with shared root CA + east-west gateways + cross-cluster remote secrets
7. Annotate the EKS east-west gateway with internet-facing NLB tags
8. Install the published operator independently on the hub and each member (no copied webhook certificates)
9. (`deploy-documentdb.sh`) Apply the `DocumentDB` CR + propagation policy; AKS becomes the primary, EKS becomes the WAL replica

**Estimated time:** 25-35 minutes for `deploy.sh`, ~5 minutes for `deploy-documentdb.sh`
**Estimated cost:** ~$13/day while running (see `infra/multi-cloud/README.md`)

Single-cluster fallbacks (`infra/azure/deploy.sh`, `infra/aws/deploy.sh`) are
still available if you want a one-cloud-at-a-time demo, but the talk targets
the multi-cloud stack.

### Phase 4: Launch the monitor + Grafana dashboards

Once both clouds are deployed and `kubectl --context azure-documentdb` /
`aws-documentdb` work, start the demo UI from the repo root:

```powershell
# From PowerShell (Windows)
.\start.ps1
# Azure-only variant:
# .\start.ps1 -MemberContexts azure-documentdb,azure-documentdb-secondary
```

```cmd
:: Or from cmd.exe / a double-click
start.bat
```

This single command:

- Sets the monitor app's env vars (`DDB_HUB_CONTEXT=hub`,
  `DDB_MEMBER_CONTEXTS=azure-documentdb,aws-documentdb`, `PORT=5174`, etc.)
- Opens the monitor app at <http://localhost:5174>
- Opens both Grafana dashboards in your browser (Azure + AWS LoadBalancer URLs;
  anonymous Viewer, no login)
- Starts `node server.js`, which spawns its own `kubectl port-forward` tunnels
  to each cluster's DocumentDB gateway — **no manual port-forward terminals
  needed**

Flags: `.\start.ps1 -NoGrafana` skips the Grafana tabs;
`.\start.ps1 -NoBrowser` skips all tabs (handy when rehearsing the server
alone). First run requires `npm install` in `app/monitor-app/` — see
[`app/monitor-app/README.md`](app/monitor-app/README.md).

---

## Cleanup / Teardown

Always tear down clusters when you're done — EKS in particular continues billing until deleted.

### Full teardown (recommended after the event)

```bash
# Multi-cloud stack (Fleet + AKS + EKS + Istio)
bash infra/multi-cloud/cleanup.sh -y --wait

# Or, if you used the standalone deploys:
bash infra/aws/cleanup.sh        # EKS only
bash infra/azure/cleanup.sh      # AKS only

# Stop the local Docker container
docker rm -f docdb
```

Both cleanup scripts:
- Prompt for confirmation by default — pass `--yes` (or `-y`) to skip in automation
- Are **safe to re-run** — each step skips if the resource is already gone
- Remove resources in dependency order (DocumentDB instance → operator → cert-manager → cluster), so cloud load balancers are released cleanly before the cluster goes away

### Verify nothing is left

```bash
# AWS
aws cloudformation list-stacks --region us-west-2 --query "StackSummaries[?contains(StackName,'docdb')]"
aws eks list-clusters --region us-west-2

# Azure
az group exists --name docdb-multicloud-rg
az group exists --name docdb-demo-rg
```

---

## Pre-Session Checklist

Run this the morning of the presentation:

- [ ] Docker Desktop is running
- [ ] Local DocumentDB container is up: `docker start docdb`
- [ ] Multi-cloud stack is up: `bash infra/scripts/start.sh` → option 3
- [ ] AKS primary reachable: `kubectl --context azure-documentdb get svc -n documentdb-preview-ns`
- [ ] EKS replica reachable: `kubectl --context aws-documentdb get svc -n documentdb-preview-ns`
- [ ] Both clusters return same `db.stays.countDocuments()` (1000)
- [ ] Indexes wiped on local instance (for live Index Advisor demo)
- [ ] Presentation deck open
- [ ] GitHub repo open in browser (for audience to follow)

---

## Cost Management

### Stop clusters after rehearsal

```bash
bash infra/scripts/stop.sh
# Option 1: Stop AKS (free, preserves state)
# Option 2: Delete EKS (stops billing, data lost)
# Option 3: Both
```

### Restart on demo day

```bash
bash infra/scripts/start.sh
# Option 3: Multi-cloud (Fleet + AKS + EKS)
```

### Destroy everything after the event

```bash
bash infra/scripts/stop.sh
# Option 5: DESTROY everything
```

### Cost estimates

| Resource | Running | Stopped |
| --- | --- | --- |
| AKS cluster | ~$17/day | ~$0.03/day (disk only) |
| EKS cluster | ~$5-8/day | $0 (must delete) |
| Local Docker | Free | Free |

---

## Data Management Scripts

| Script | Purpose | Usage |
| --- | --- | --- |
| `data/load-data.sh` | Import 1,000 listings + create vector & query indexes | `MONGODB_URI="..." bash data/load-data.sh` |
| `data/wipe-data.sh --all` | Drop entire database (clean slate) | Full reset for data import demo |
| `data/wipe-data.sh --indexes` | Drop all indexes, keep data | Ready for Index Advisor demo |
| `data/wipe-data.sh --data` | Delete documents, keep indexes | Reset data only |

All scripts default to local connection. Set `MONGODB_URI` for AKS/EKS targets.

---

## Demo Flow Summary

| Demo | Time | What's Pre-loaded | What You Do Live |
| --- | --- | --- | --- |
| 01 - Local dev | 5 min | Docker running | Connect VS Code, import data, run queries |
| 02 - Vector search | 12 min | Data loaded, indexes wiped | Create vector index, run semantic search, Index Advisor |
| 03 - CI/CD | 3 min | GitHub Actions configured | Show workflow file, explain, show passing run |
| 04 - AKS | 5 min | Multi-cloud stack deployed, data loaded on AKS primary | Show kubectl, connect, run queries |
| 05 - EKS | 4 min | Same stack — EKS is the WAL replica | Switch context, show identical data via replication |
| 06 - Multi-cloud | 5 min | Fleet+Istio mesh up, replication healthy | Insert sentinel doc, `kubectl documentdb promote` failover |

---

## Troubleshooting

### Docker container won't start
```bash
docker rm -f docdb
docker run -dt -p 10260:10260 --name docdb \
  ghcr.io/documentdb/documentdb/documentdb-local:latest \
  --username demo --password test
```

### Connection refused on port 10260
- Check Docker is running: `docker ps`
- Check port isn't in use: `lsof -i :10260` (macOS/Linux) or `netstat -an | findstr 10260` (Windows)

### AKS LoadBalancer stuck in Pending
```bash
kubectl describe svc -n documentdb-ns
# Check for quota or networking issues
```

### EKS NLB not provisioning
```bash
# Verify AWS Load Balancer Controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Vector search returns no results
- Verify vector index exists: `db.listings.getIndexes()`
- Verify documents have `descriptionVector` field: `db.listings.findOne({}, {descriptionVector: {$exists: true}})`
- Check OpenAI API key is set in `.env`
