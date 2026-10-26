#!/bin/bash
# Start demo infrastructure - spin up both AKS and EKS clusters
# Run this before rehearsing or on demo day
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
MC_RG="${MC_RG:-${RESOURCE_GROUP:-docdb-multicloud-rg}}"
RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-demo-rg}"
AKS_CLUSTER="${AKS_CLUSTER:-docdb-demo-aks}"
EKS_CLUSTER="${EKS_CLUSTER:-docdb-demo-eks}"
EKS_REGION="${EKS_REGION:-us-west-2}"

echo "============================================"
echo "  DocumentDB Demo Infrastructure - START"
echo "============================================"
echo ""

# Check prerequisites
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "❌ Helm required"; exit 1; }

echo "Choose what to start:"
echo "  1) AKS only (Azure)"
echo "  2) EKS only (AWS)"
echo "  3) Multi-cloud (AKS Fleet hub + AKS member + EKS, fleet+Istio replication)"
echo "  4) Local only (Docker)"
read -rp "Selection [1-4]: " choice

case $choice in
  1)
    echo ""
    echo "=== Starting AKS cluster ==="
    # Start stopped AKS cluster
    az aks start --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" 2>/dev/null || {
      echo "Cluster not found. Deploying new cluster..."
      bash "$REPO_ROOT/infra/azure/deploy.sh"
    }
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" --overwrite-existing
    echo "✅ AKS cluster running"
    kubectl get nodes
    ;;
  2)
    echo ""
    echo "=== Starting EKS cluster ==="
    # Check if EKS cluster exists
    aws eks describe-cluster --name "$EKS_CLUSTER" --region "$EKS_REGION" >/dev/null 2>&1 || {
      echo "Cluster not found. Deploying new cluster..."
      bash "$REPO_ROOT/infra/aws/deploy.sh"
    }
    aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$EKS_REGION"
    echo "✅ EKS cluster running"
    kubectl get nodes
    ;;
  3)
    echo ""
    echo "=== Multi-cloud (Fleet + Istio) ==="
    # The multi-cloud playground stands up a fresh fleet hub, AKS member,
    # and EKS member with a real Istio mesh between them. It is NOT designed
    # to start/stop incrementally — if the fleet doesn't exist, deploy it.
    export RESOURCE_GROUP="$MC_RG"
    source "$REPO_ROOT/infra/multi-cloud/config.sh"
    if az group show --name "$MC_RG" --output none 2>/dev/null \
       && az fleet list -g "$MC_RG" --query "[0].name" -o tsv 2>/dev/null | grep -q .; then
      echo "Multi-cloud stack already deployed in $MC_RG."
      echo "Refreshing kubectl contexts..."
      FLEET_NAME=$(az fleet list -g "$MC_RG" --query "[0].name" -o tsv)
      az fleet get-credentials --resource-group "$MC_RG" --name "$FLEET_NAME" --overwrite-existing
      for member in "${AKS_MEMBER_NAMES[@]}"; do
        az aks get-credentials --resource-group "$MC_RG" --name "$member" --context "$member" --overwrite-existing
      done
      if [ "$INCLUDE_EKS" = true ]; then
        aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" --alias "$EKS_CLUSTER_NAME"
      fi
    else
      echo "Multi-cloud stack not found. Deploying (~25-35 min)..."
      bash "$REPO_ROOT/infra/multi-cloud/deploy.sh"
      echo ""
      echo "Now deploying DocumentDB across the mesh..."
      bash "$REPO_ROOT/infra/multi-cloud/deploy-documentdb.sh"
    fi
    echo ""
    echo "✅ Multi-cloud ready. Contexts:"
    echo "  $HUB_CONTEXT (Fleet hub)"
    printf '  %s\n' "${MEMBER_CLUSTER_NAMES[@]}"
    echo ""
    echo "Status:"
    kubectl --context "$HUB_CONTEXT" get clusterresourceplacement
    ;;
  4)
    echo ""
    echo "=== Starting local DocumentDB ==="
    docker compose -f "$REPO_ROOT/docker-compose.yml" up -d
    echo "DocumentDB local running on port 27017"
    ;;
  *)
    echo "Invalid selection"
    exit 1
    ;;
esac

echo ""
echo "============================================"
echo "  Infrastructure ready for demo"
echo "============================================"
