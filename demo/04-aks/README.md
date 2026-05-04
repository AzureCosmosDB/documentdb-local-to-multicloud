# Demo 04: Deploy to Azure Kubernetes Service (AKS)

**Time: ~5 minutes (pre-deployed, show results)**

> **Pre-deploy before the session**: `bash infra/scripts/start.sh` → option 3
> (multi-cloud). The AKS member cluster is part of the AKS Fleet that runs the
> primary DocumentDB. There is no longer a "AKS only" mode for the talk —
> demos 04, 05, and 06 share one fleet-managed deployment.

## What You'll Show

1. The DocumentDB operator running on the AKS member cluster (propagated
   from the Fleet hub via `ClusterResourcePlacement`)
2. A `DocumentDB` custom resource on the AKS member acting as the **primary**
3. External access via an Azure LoadBalancer in eastus2
4. The same MongoDB connection string pattern as local

## Cluster names

| Context | Cluster | Region | Role today |
|---|---|---|---|
| `hub` | AKS Fleet hub | eastus2 | Control plane (no workloads) |
| `azure-documentdb` | AKS member | eastus2 | DocumentDB **primary** |
| `aws-documentdb` | EKS member | us-west-2 | DocumentDB WAL replica |

## Steps (during demo, cluster is already running)

### 1. Show the cluster

```bash
kubectl --context azure-documentdb get nodes
kubectl --context azure-documentdb get pods -n documentdb-operator
kubectl --context azure-documentdb get documentdb,pods -n documentdb-preview-ns
```

### 2. Show the custom resource — note `clusterReplication`

```bash
kubectl --context azure-documentdb describe documentdb documentdb-preview \
  -n documentdb-preview-ns
```

Point out:
- `spec.clusterReplication.primary: azure-documentdb`
- `spec.clusterReplication.crossCloudNetworkingStrategy: Istio`
- The cluster list — AKS + EKS both listed

### 3. Get connection info

```bash
# External IP of the LoadBalancer
kubectl --context azure-documentdb get svc -n documentdb-preview-ns

# The auto-generated password (set by deploy-documentdb.sh)
kubectl --context azure-documentdb get secret documentdb-credentials \
  -n documentdb-preview-ns -o jsonpath='{.data.password}' | base64 -d
```

**Two ways to connect:**

**(a) Direct via LoadBalancer** — public endpoint, occasionally flaky on the
TLS handshake (gateway uses self-signed `localhost` cert):
```bash
mongosh "mongodb://docdb:<password>@<EXTERNAL-IP>:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256"
```

**(b) Persistent port-forward (recommended for VS Code + reliable demos)**:
```bash
CONTEXT=azure-documentdb \
NAMESPACE=documentdb-preview-ns \
SERVICE=documentdb-service-documentdb-preview \
LOCAL_PORT=11260 \
infra/scripts/portforward.sh
```

In **VS Code → DocumentDB extension → + Add Connection**:
```
mongodb://docdb:<password>@localhost:11260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256
```
Label it `AKS — primary (port-fwd)`.

### 4. Load the dataset (one-time, before the talk)

Load on the **primary only** — the EKS replica picks it up via WAL streaming.

```bash
MONGODB_URI="mongodb://docdb:<password>@localhost:11260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256" \
  ./data/load-data.sh
```

### 5. Show the data

```javascript
use demodb
db.stays.countDocuments()                         // 1000
db.stays.find({ property_type: "Entire home/apt" }).limit(3)
db.stays.find({ tags: { $all: ["downtown", "wifi"] } }).limit(5)
```

## How it was deployed

Walk through `infra/multi-cloud/deploy.sh`:
1. Bicep deploys the AKS Fleet + the AKS member in eastus2
2. EKS is created in parallel via eksctl
3. EKS joins the Fleet via the open-source kubefleet bootstrap
4. cert-manager + Istio multi-cluster mesh (shared root CA, east-west gateways)
5. DocumentDB operator installed on the **hub**, propagated to members via
   `ClusterResourcePlacement` (so the operator binary is identical everywhere)
6. `deploy-documentdb.sh` applies the `DocumentDB` CR + propagation policy

## Talking points

- "Same DocumentDB, now on Kubernetes — and propagated by Fleet to every
  member of the mesh."
- "Operator manages lifecycle — scaling, backups, **failover**."
- "The application's connection string is the only thing that changes
  between local and cloud — the queries don't."
- "The AKS member is the primary today, but I'll flip that on stage in demo 06."
