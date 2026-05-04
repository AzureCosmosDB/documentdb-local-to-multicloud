# Multi-cloud DocumentDB (AKS Fleet + Istio mesh + WAL replication)

This is the **vendored, AKS+EKS-default** version of the upstream
[`documentdb-playground/multi-cloud-deployment`](https://github.com/documentdb/documentdb-kubernetes-operator/tree/main/documentdb-playground/multi-cloud-deployment).

It replaces the standalone AKS (`infra/azure/`) and EKS (`infra/aws/`) deploys
with a single fleet-managed deployment that gives **real cross-cloud
replication** instead of two unrelated clusters.

## What gets created

| Resource | Where | Purpose |
|---|---|---|
| Resource group `docdb-multicloud-rg` | Azure (eastus2) | Holds the Fleet hub + AKS member |
| AKS Fleet `aks-fleet-hub-fleet` | Azure (eastus2) | KubeFleet control plane that propagates DocumentDB CRDs/RBAC and the DocumentDB CR via `ClusterResourcePlacement` |
| AKS member `azure-documentdb` | Azure (eastus2) | Runs a primary or replica of DocumentDB |
| EKS cluster `aws-documentdb` | AWS (us-west-2) | Joined to the Fleet via the open-source kubefleet bootstrap; runs the other replica |
| Istio 1.24 multi-cluster mesh | All members | Shared root CA, east-west gateways, cross-cluster service discovery + mTLS |
| AWS NLB on `istio-eastwestgateway` | EKS | Exposes the EKS east-west gateway to the AKS east-west gateway over the public internet (mTLS-secured) |
| DocumentDB operator | Hub → propagated to members | Manages `DocumentDB` CR, drives CNPG WAL replication |
| `DocumentDB documentdb-preview` | namespace `documentdb-preview-ns` | The actual database; primary on AKS, WAL replica on EKS |

## How replication works (one-paragraph version)

The DocumentDB operator watches the `DocumentDB` CR. On the cluster that matches
`spec.clusterReplication.primary` it creates a CNPG primary cluster; on every
other cluster in `spec.clusterReplication.clusterList` it creates a **WAL
replica** that subscribes to the primary's WAL stream over the Istio mesh.
Istio's east-west gateways + remote secrets give every cluster a routable view
of every other cluster's services (`documentdb-preview-rw.documentdb-preview-ns`
resolves cross-cluster), so the replica's CNPG instance can stream WAL records
from the primary as if they were on the same network — without exposing the
Postgres port publicly.

`kubectl documentdb promote` flips which cluster is primary by reconfiguring the
CR; the new primary's CNPG cluster is promoted, the old primary becomes a
replica, and (if Azure DNS is enabled) the SRV record is updated so MongoDB
clients reconnect automatically.

## Quick start

```bash
# Stand up infra (AKS Fleet + AKS + EKS + Istio + operator). ~25-35 min.
bash infra/multi-cloud/deploy.sh

# Deploy a DocumentDB cluster (primary defaults to AKS).
bash infra/multi-cloud/deploy-documentdb.sh
# Save the printed password.
```

## Configuration (env vars)

| Var | Default | Notes |
|---|---|---|
| `RESOURCE_GROUP` | `docdb-multicloud-rg` | Azure RG that holds Fleet hub + AKS member |
| `RG_LOCATION` / `HUB_REGION` / `AKS_REGION` | `eastus2` | Azure regions |
| `AKS_CLUSTER_NAME` | `azure-documentdb` | AKS member name; also kubectl context |
| `EKS_CLUSTER_NAME` | `aws-documentdb` | EKS cluster name; also kubectl context |
| `EKS_REGION` | `us-west-2` | AWS region |
| `EKS_NODE_TYPE` | `m5.large` | EKS node SKU |
| `HUB_VM_SIZE` | (Bicep default `Standard_DS3_v2`) | AKS member VM SKU |
| `INCLUDE_GKE` | `false` | Set `true` to add a GKE member; requires `PROJECT_ID`, `GCP_USER`, `gcloud` |
| `OPERATOR_CHART_DIR` | auto | Local path to `documentdb-helm-chart`; if unset we look for a sibling `documentdb-kubernetes-operator/` clone and create one if missing |
| `VERSION` | `200` | Operator chart `0.0.<VERSION>` package version |
| `PRIMARY_CLUSTER` | `$AKS_CLUSTER_NAME` | Which member starts as primary |
| `ENABLE_AZURE_DNS` | `false` | Skip Azure DNS zone management; set `true` plus `AZURE_DNS_PARENT_ZONE_RESOURCE_ID` to expose the cluster as a `mongodb+srv://` URL |
| `DELETE_EXISTING` | (prompt) | `true` recreates DocumentDB resources non-interactively, `false` updates in place |

## Failover

```bash
# Promote EKS to primary
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace documentdb-preview-ns \
  --hub-context hub \
  --target-cluster aws-documentdb \
  --cluster-context aws-documentdb

# Promote back to AKS
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace documentdb-preview-ns \
  --hub-context hub \
  --target-cluster azure-documentdb \
  --cluster-context azure-documentdb
```

The `kubectl documentdb` plugin ships with the operator chart and is installed
on the hub via Helm.

## Rough cost

| Component | $/day (running) |
|---|---|
| AKS Fleet hub (no node pool) | ~$0 |
| AKS member (1× Standard_DS3_v2) | ~$5 |
| EKS control plane | ~$2.40 |
| EKS workers (2× m5.large) | ~$4.60 |
| AWS NLB + cross-zone | ~$0.60 + bandwidth |
| Disks | ~$0.15 |
| **Total (AKS+EKS)** | **~$13/day** |

GKE third leg adds another ~$8/day.

## Cleanup

```bash
bash infra/multi-cloud/cleanup.sh -y --wait
```

## Differences from upstream

* GKE is **opt-in** (`INCLUDE_GKE=true`) — upstream always deploys GKE.
* Operator helm chart is loaded from a sibling clone (so this directory stays
  small); upstream expects the script to live inside the operator repo.
* Default resource group is `docdb-multicloud-rg` (upstream uses
  `documentdb-aks-fleet-rg`).
* `deploy-documentdb.sh` defaults primary to **AKS** (closest to the Fleet hub).
  Upstream defaults to whatever `${CLUSTER_ARRAY[1]}` resolves to (AKS in their
  ordering, but the choice was implicit).
* `ENABLE_AZURE_DNS` defaults to `false` (no DNS zone management for the demo).
* `DELETE_EXISTING` env var lets `deploy-documentdb.sh` run non-interactively.
* `cleanup.sh` added to mirror the Azure / AWS standalone cleanup style.

## Re-syncing from upstream

```bash
git -C ~/GitHub/DocumentDB/documentdb-kubernetes-operator pull
diff -u ~/GitHub/DocumentDB/documentdb-kubernetes-operator/documentdb-playground/multi-cloud-deployment/main.bicep \
        infra/multi-cloud/main.bicep
```

The Bicep / YAML / `dns_failover.sh` files in this folder are unmodified copies
from upstream (only `deploy.sh`, `deploy-documentdb.sh`, `cleanup.sh`, and this
README were rewritten).
