# Demo 06: Multi-Cloud High Availability and Failover

**Time: ~5 minutes**

> Builds on demos 04 (AKS primary) and 05 (EKS WAL replica). One DocumentDB,
> two clouds, real cross-cloud replication via KubeFleet + Istio + CNPG WAL
> streaming.

## What You'll Show

1. One `DocumentDB` CR — same name, same namespace — on both clusters,
   one acting as **primary**, one acting as **WAL replica**
2. A write on the primary appears on the replica in seconds
3. `kubectl documentdb promote` flips the primary to the other cloud
   in one command, no application code changes
4. The (former) primary becomes the new replica and continues streaming

## Architecture (summary — full diagram in the deck)

```
                        AKS Fleet hub  (eastus2)
                              │  ClusterResourcePlacement
                  ┌───────────┴───────────┐
                  │                       │
     AKS member (eastus2)         EKS member (us-west-2)
   ┌──────────────────────┐    ┌──────────────────────┐
   │ DocumentDB operator  │    │ DocumentDB operator  │
   │ CNPG primary (RW)    │◄───│ CNPG WAL replica (RO)│
   │ Istio east-west GW   │   ──► Istio east-west GW  │
   │ Azure LoadBalancer   │  mTLS over public internet │
   └──────────────────────┘    └──────────────────────┘
              ▲                            ▲
              │ port-forward 11260         │ port-forward 12260
              └─── docdb (mongosh / VS Code DocumentDB ext) ───┘
```

## Steps

### 1. Show one CR, both clusters

```bash
kubectl --context azure-documentdb get documentdb,pods -n documentdb-preview-ns
kubectl --context aws-documentdb   get documentdb,pods -n documentdb-preview-ns
```

Same `documentdb-preview` resource on both. On AKS you'll see a CNPG primary
pod; on EKS you'll see a `wal-replica` pod with an Istio sidecar.

### 2. Same query, both clouds

In **VS Code → DocumentDB extension**, switch between connections:

- `AKS — primary (port-fwd)` → `mongodb://docdb:<password>@localhost:11260/...`
- `EKS — replica (port-fwd)` → `mongodb://docdb:<password>@localhost:12260/...`

```javascript
use demodb
db.stays.countDocuments()                          // 1000 in both
db.stays.find({ tags: "hot-tub" }).count()         // identical in both
```

### 3. Write to primary, read from replica

```javascript
// On AKS (primary)
db.stays.insertOne({
  _id: "replication-sentinel-1",
  source: "aks-primary",
  ts: new Date(),
  note: "Hello from Azure"
})
```

Wait 2-5 seconds, then on EKS:

```javascript
db.stays.findOne({ _id: "replication-sentinel-1" })
// → { _id: "replication-sentinel-1", source: "aks-primary", ... }
```

> **What's happening under the hood**: CNPG's `Subscription` resource on the
> EKS replica is consuming WAL records from the AKS primary. The Postgres
> replication protocol speaks to the primary's `documentdb-service-rw`
> service, but on EKS that name resolves (via Istio multi-cluster) to a pod
> on the AKS cluster, routed through the east-west gateways with mTLS.

### 4. One-command failover (the money shot)

```bash
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace documentdb-preview-ns \
  --hub-context hub \
  --target-cluster aws-documentdb \
  --cluster-context aws-documentdb
```

What happens:
1. The CR's `spec.clusterReplication.primary` is updated to `aws-documentdb`
2. The operator on EKS promotes the CNPG cluster to writable
3. The operator on AKS demotes the previous primary to a WAL replica
4. (If `ENABLE_AZURE_DNS=true`) the SRV record `_mongodb._tcp.<zone>` is
   updated so `mongodb+srv://` clients resolve to the new primary

Verify:
```bash
kubectl --context hub get documentdb documentdb-preview -n documentdb-preview-ns \
  -o jsonpath='{.spec.clusterReplication.primary}'  # → aws-documentdb
kubectl --context aws-documentdb get pods -n documentdb-preview-ns
```

### 5. Write to the new primary

```javascript
// On EKS (now primary)
db.stays.insertOne({
  _id: "replication-sentinel-2",
  source: "eks-primary-after-failover",
  ts: new Date()
})
```

Then on AKS (now replica):
```javascript
db.stays.findOne({ _id: "replication-sentinel-2" })
```

### 6. Failover back

```bash
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace documentdb-preview-ns \
  --hub-context hub \
  --target-cluster azure-documentdb \
  --cluster-context azure-documentdb
```

## Talking points

- "One Kubernetes object, two clouds. KubeFleet propagates it. Istio gives
  the replicas a routable view of the primary's services as if they were
  on the same network."
- "The actual replication is **real PostgreSQL WAL streaming** through CNPG —
  not async batched copy, not eventual consistency hand-waving."
- "Failover is one `kubectl` command. The MongoDB connection string doesn't
  change. The application code doesn't change."
- "Run a third leg in GKE for true geo-distribution? `INCLUDE_GKE=true`."
- "Production hardening: enable Azure DNS for SRV-based client routing, add
  the `telemetry/` Grafana stack, hook backups to object storage. All in the
  upstream playground."

## Cleanup

```bash
bash infra/multi-cloud/cleanup.sh -y --wait
```
