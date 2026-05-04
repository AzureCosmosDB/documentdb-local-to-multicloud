# Setup Guide

Complete setup instructions for the "From Localhost to Multi-Cloud" demo environment.

> **Windows users**: the deploy/cleanup scripts under `infra/` are bash scripts. Run them from **Git Bash** (recommended) or **WSL**. PowerShell works for the `docker compose`, `python`, and `az`/`aws` CLI commands but cannot execute the `.sh` files directly.

## Prerequisites

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
- **AWS account** with IAM permissions for EKS, EBS, and Load Balancer

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

# 5. (Data is auto-loaded by docker compose — 20K restaurants + vectors)
# Verify:
mongosh "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --eval "use('foodservice'); db.restaurants.countDocuments()"

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

### Phase 3: Deploy to AKS (Azure)

```bash
# Login to Azure
az login

# Deploy AKS + DocumentDB operator + instance + load data + wipe indexes
bash infra/azure/deploy.sh
```

This will:
1. Create resource group `docdb-demo-rg` in `eastus2`
2. Deploy AKS cluster via Bicep
3. Install cert-manager + DocumentDB operator via Helm
4. Deploy DocumentDB instance with LoadBalancer
5. Wait for external IP
6. Load 1,000 listings with vector embeddings
7. Wipe indexes (data stays, ready for Index Advisor demo)

**Estimated time:** 15-20 minutes
**Estimated cost:** ~$17/day ($512/month) while running

### Phase 4: Deploy to EKS (AWS)

```bash
# Configure AWS CLI (or 'aws sso login' if your account uses IAM Identity Center)
aws configure

# Deploy EKS + DocumentDB operator + instance + load data + wipe indexes
bash infra/aws/deploy.sh
```

This will:
1. Create EKS cluster via eksctl
2. Install EBS CSI driver + cert-manager + DocumentDB operator
3. Deploy DocumentDB instance with NLB
4. Wait for NLB hostname
5. Load 1,000 listings with vector embeddings
6. Wipe indexes (data stays, ready for Index Advisor demo)

**Estimated time:** 20-25 minutes
**Estimated cost:** ~$5-8/day ($140-230/month) while running

The script is **idempotent** — re-running it skips cluster creation if it already exists, upgrades the helm release in place, and reuses the password stored in the `docdb-demo-password` Secret.

### Phase 5: Multi-Cloud (both clusters)

Use `infra/scripts/start.sh` → option 3 to verify both clusters are running, or deploy individually using Phases 4 and 5.

---

## Cleanup / Teardown

Always tear down clusters when you're done — EKS in particular continues billing until deleted.

### Full teardown (recommended after the event)

```bash
# AWS (deletes EKS cluster and all dependencies, ~10-12 min)
bash infra/aws/cleanup.sh

# Azure (deletes the entire docdb-demo-rg resource group)
bash infra/azure/cleanup.sh

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
az group exists --name docdb-demo-rg
```

---

## Pre-Session Checklist

Run this the morning of the presentation:

- [ ] Docker Desktop is running
- [ ] Local DocumentDB container is up: `docker start docdb`
- [ ] AKS cluster is running: `bash infra/scripts/start.sh` → option 1
- [ ] EKS cluster is running: `bash infra/scripts/start.sh` → option 2
- [ ] VS Code extension connected to local instance
- [ ] OpenAI API key in `.env`
- [ ] Test vector search works locally
- [ ] Verify AKS external IP: `kubectl --context aks-demo get svc -n documentdb-ns`
- [ ] Verify EKS NLB hostname: `kubectl --context eks-demo get svc -n documentdb-ns`
- [ ] Both clusters have data loaded (check document counts)
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
# Option 3: Start both clusters
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
| 04 - AKS | 5 min | Cluster deployed, data loaded | Show kubectl, connect, run queries |
| 05 - EKS | 4 min | Cluster deployed, data loaded | Switch context, side-by-side comparison |
| 06 - Multi-cloud | 5 min | Both clusters running | Show replication, simulate failover |

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
