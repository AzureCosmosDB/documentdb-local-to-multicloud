# DocumentDB regional and multi-cloud deployment

One DocumentDB resource, replicated by PostgreSQL WAL across separate Kubernetes
clusters. The default remains AKS + EKS. A second AKS cluster in a different
Azure region can replace EKS or run alongside it. This is **operator-managed
DocumentDB on PostgreSQL**, not a separate plain PostgreSQL service.

The Fleet hub places the database namespace, credentials and DocumentDB resource
only on the configured members. Each cluster gets its own published operator
chart, certificates and webhook configuration; operators are no longer copied
from the hub. Istio east-west gateways and remote secrets connect every pair of
members. PostgreSQL replication uses Istio mTLS on port 5432, not a public
PostgreSQL endpoint.

## Prerequisites and versions

See [SETUP.md](../../SETUP.md) before upgrading an existing deployment. All members
need Kubernetes 1.35+ with ImageVolume enabled and a compatible container runtime.
The Fleet hub must meet the operator chart's Kubernetes 1.33+ floor.
Region availability and quotas must be checked before deploying.

`infra/versions.sh` pins operator/engine **1.0.0**, cert-manager **1.21.3**,
Istio **1.30.7**, and kube-prometheus-stack **92.14.0**. The operator chart
includes CNPG chart **0.28.3**. Istio 1.31.3 has a GitHub release but its chart was
not available in either official chart registry when checked on 2026-10-26;
1.30.7 was the latest stable published chart that rendered successfully.
Fleet bootstrap revisions remain explicitly pinned for the managed Fleet setup.

Required tools: Azure CLI, kubectl, Helm 3, Git, Bash, jq, curl, make, OpenSSL,
and kubelogin. AWS CLI and eksctl are required **only when EKS is enabled**.
The deploy script installs the Azure Fleet CLI extension if missing.
The monitor additionally needs Node.js 24 LTS and the local
[`kubectl documentdb` plugin](../../SETUP.md#kubectl-plugin).

## Provisioning

These commands create billable resources. Nothing is deployed by installing
the monitor's npm dependencies or running its tests.

```bash
# Original AKS + EKS path:
az login
aws sso login
bash infra/multi-cloud/deploy.sh
bash infra/multi-cloud/deploy-documentdb.sh
bash monitoring/deploy.sh
```

For Azure-only regional failover, choose an available second region explicitly:

```bash
export INCLUDE_EKS=false
export INCLUDE_AKS_REPLICA=true
export AKS_REPLICA_REGION="<second-region>"
export RESOURCE_GROUP="docdb-regional-rg"

az login
bash infra/multi-cloud/deploy.sh
bash infra/multi-cloud/deploy-documentdb.sh
bash monitoring/deploy.sh
```

Set `INCLUDE_EKS=true` with the same regional settings to use all three members.
Use the **same exported configuration** for deployment, monitoring, refresh and
cleanup. Each member name must be unique and must also be its kubeconfig context
and Fleet member name. Cloud/provider names are never used as unique identities.

| Variable | Default | Meaning |
|---|---|---|
| `RESOURCE_GROUP` | `docdb-multicloud-rg` | Dedicated Azure RG, deleted in full by cleanup |
| `RG_LOCATION`, `HUB_REGION`, `AKS_REGION` | `eastus2` | RG, hub and first member locations |
| `AKS_CLUSTER_NAME` | `azure-documentdb` | First AKS member/context |
| `INCLUDE_AKS_REPLICA` | `false` | Provision second AKS member |
| `AKS_REPLICA_NAME` | `azure-documentdb-secondary` | Second AKS member/context |
| `AKS_REPLICA_REGION` | none | Required, different from `AKS_REGION` |
| `INCLUDE_EKS` | `true` | Provision/use EKS |
| `EKS_CLUSTER_NAME`, `EKS_REGION` | `aws-documentdb`, `us-west-2` | EKS identity/location |
| `INCLUDE_GKE` | `false` | Optional GKE member; needs `GCP_PROJECT_ID`, `GCP_USER`, `gcloud` |
| `HUB_CONTEXT` | `hub` | Fleet hub context |
| `KUBERNETES_VERSION` | `1.35` | Supported regional version with ImageVolume |
| `HUB_VM_SIZE` | `Standard_DS3_v2` | AKS member node SKU |
| `PRIMARY_CLUSTER` | first AKS member | Initial primary; updates preserve the existing primary and reject changing/removing it (use promotion first) |
| `VALUES_FILE` | none | Additional operator Helm values |
| `ENABLE_AZURE_DNS` | `false` | Optional DNS; see deployment script's zone settings |
| `DELETE_EXISTING` | `false` | `true` explicitly deletes existing database resources; otherwise prompts |

Generated passwords are stored in the credentials Secret and not printed.
Updating a database reuses its existing credentials. `--render` is cloud-free:

```bash
DOCUMENTDB_PASSWORD=offline-example bash infra/multi-cloud/deploy-documentdb.sh --render
```

The rendered output contains a base64-encoded password. Use a dummy value for
review and never commit real rendered Secrets. Preserve `infra/multi-cloud/certs/`
securely when adding a member: the script refuses to silently replace a live
mesh's missing local root CA.

## Promotion and application routing

Use the existing **Promote to primary** control on either replica's card.
The monitor checks all active members, current leaders, replica sources and WAL
receivers, serializes topology operations, then invokes the supported plugin.
Bookings and Load resolve the current primary by member identity; Vector Search
continues to use the local Docker instance.

```bash
kubectl documentdb promote --documentdb documentdb-preview \
  --namespace documentdb-preview-ns --hub-context hub \
  --target-cluster azure-documentdb-secondary \
  --cluster-context azure-documentdb-secondary
```

This is a **planned switchover**, requiring healthy replication and the old
primary. Streaming status is not proof of zero lag or zero data loss. The monitor
does not pass `--failover` or bypass health checks. An unavailable primary needs
the upstream disaster-recovery procedure, including fencing and an explicit
data-loss decision. Do not run multiple monitor processes to operate the same
topology concurrently.

The monitor does not change external DNS. If optional Azure DNS is used, update
the SRV record only after the new primary has completed promotion.

## Monitoring and cleanup

`monitoring/deploy.sh` installs Grafana/Prometheus on every enabled member. The
operator's bundled CNPG exporter uses `monitoring/queries.yaml`; the dashboard
uses the corresponding `cnpg_` metrics. The legacy standalone exporter manifest
is not applied. Grafana discovery uses each member context, not hardcoded IPs.
The bundled Grafana values expose anonymous demo dashboards; restrict access
before using anything beyond non-sensitive demonstration data.

```bash
bash infra/multi-cloud/cleanup.sh       # displays scope and asks for "destroy"
# Explicit noninteractive destruction:
bash infra/multi-cloud/cleanup.sh -y --wait
```

Cleanup deletes the whole configured Azure RG, including both AKS members,
and only the enabled external-cloud members/contexts. Do not share that RG with
unrelated resources. A second AKS region adds node, disk, gateway and inter-region
traffic costs; it does not eliminate infrastructure cost.

## Sources

- [Operator 1.0.0 release and migration requirements](https://github.com/documentdb/documentdb-kubernetes-operator/releases/tag/1.0.0)
- [Released promotion implementation](https://github.com/documentdb/documentdb-kubernetes-operator/blob/1.0.0/documentdb-kubectl-plugin/cmd/promote.go)
- [Released replication/token cleanup](https://github.com/documentdb/documentdb-kubernetes-operator/blob/1.0.0/operator/src/internal/controller/physical_replication.go)
- [AKS multi-region guidance](https://learn.microsoft.com/azure/aks/reliability-multi-region-deployment-models)
