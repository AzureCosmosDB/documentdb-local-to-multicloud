# Demo 05: Deploy to AWS Elastic Kubernetes Service (EKS)

**Time: ~4 minutes (pre-deployed, show results)**

> **Pre-deploy before the session**: same multi-cloud `start.sh` option 3 as
> demo 04. The EKS cluster is the **WAL replica** of the AKS primary,
> connected over an Istio multi-cluster mesh.

## What You'll Show

1. Same operator, same Helm chart, **literally the same DocumentDB CR** —
   propagated to EKS by KubeFleet
2. A WAL replica pod streaming changes from the AKS primary over Istio
3. Reads against the EKS replica return the same data as the AKS primary
4. The connection string pattern is identical to AKS

## Cluster names

| Context | Cluster | Region | Role today |
|---|---|---|---|
| `aws-documentdb` | EKS | us-west-2 | DocumentDB WAL replica |
| `azure-documentdb` | AKS member | eastus2 | DocumentDB primary |

## Steps (during demo, cluster is already running)

### 1. Switch context and show the cluster

```bash
kubectl --context aws-documentdb get nodes
kubectl --context aws-documentdb get documentdb,pods -n documentdb-preview-ns
kubectl --context aws-documentdb get svc -n documentdb-preview-ns
```

Look for the `wal-replica` pod with an Istio sidecar:
```bash
kubectl --context aws-documentdb get pods -n documentdb-preview-ns \
  -l component=wal-replica -o wide
```

### 2. Show the operator was propagated by Fleet

```bash
kubectl --context hub get clusterresourceplacement -o wide
```

`documentdb-base` and `documentdb-crp` should both show `Synchronized=True`
on every member — that is what got the operator + the CR onto EKS.

### 3. Connect to the replica

**Two ways** — same trade-off as AKS (see demo 04 for the "why"):

**(a) Direct via NLB** — works for `mongosh`, occasionally flaky on first TLS
handshake:
```bash
mongosh "mongodb://docdb:<password>@<NLB-HOSTNAME>:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256"
```

**(b) Persistent port-forward (recommended for VS Code + reliable demos)**:
```bash
CONTEXT=aws-documentdb \
NAMESPACE=documentdb-preview-ns \
SERVICE=documentdb-service-documentdb-preview \
LOCAL_PORT=12260 \
infra/scripts/portforward.sh
```

In **VS Code → DocumentDB extension → + Add Connection**:
```
mongodb://docdb:<password>@localhost:12260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256
```
Label it `EKS — replica (port-fwd)`.

> The deploy-documentdb.sh password may contain `/` and `=`; URL-encode them
> if you embed the URI somewhere that doesn't tolerate raw chars
> (`/` → `%2f`, `=` → `%3d`).

### 4. Verify replication (no data load step on EKS!)

You did not run `load-data.sh` against EKS — it was never necessary, because
the data streamed in from AKS via WAL.

```javascript
use demodb
db.stays.countDocuments()                         // 1000 — same as AKS
db.stays.find({ tags: { $all: ["downtown", "wifi"] } }).limit(5)
```

### 5. Side-by-side comparison

Show two terminals or two VS Code DocumentDB tabs:
- Left: `AKS — primary (port-fwd)` (writes go here)
- Right: `EKS — replica (port-fwd)` (reads return identical data)

```javascript
// On AKS
db.stays.insertOne({ _id: "replication-sentinel-1", note: "hello from AKS primary", ts: new Date() })

// Wait ~2-5 seconds, then on EKS
db.stays.findOne({ _id: "replication-sentinel-1" })
```

## Key differences from AKS (the only ones)

| Aspect | AKS member | EKS member |
|---|---|---|
| Storage class | managed-csi (default) | `documentdb-storage` (gp3) |
| Load balancer | Azure LB | AWS NLB (annotated internet-facing) |
| Auth | Azure AD / Entra | IRSA (IAM roles for service accounts) |
| **Operator + DocumentDB CR** | **Identical (propagated by Fleet)** | **Identical** |

## Talking points

- "Exact same Helm chart, exact same operator, exact same `DocumentDB` CR —
  the only `clusterReplication.clusterList` entry that's different is the
  `storageClass` override for EKS gp3."
- "The replica is reading from the primary over an mTLS-secured Istio tunnel
  between an AKS east-west gateway in eastus2 and an internet-facing NLB in
  us-west-2."
- "Your application code is 100% unchanged."
