#!/bin/bash
# Start demo infrastructure - spin up both AKS and EKS clusters
# Run this before rehearsing or on demo day
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
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
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI required"; exit 1; }
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
    MC_RG="${MC_RG:-docdb-multicloud-rg}"
    if az group show --name "$MC_RG" --output none 2>/dev/null \
       && az fleet list -g "$MC_RG" --query "[0].name" -o tsv 2>/dev/null | grep -q .; then
      echo "Multi-cloud stack already deployed in $MC_RG."
      echo "Refreshing kubectl contexts..."
      FLEET_NAME=$(az fleet list -g "$MC_RG" --query "[0].name" -o tsv)
      az fleet get-credentials --resource-group "$MC_RG" --name "$FLEET_NAME" --overwrite-existing
      az aks get-credentials --resource-group "$MC_RG" --name "${AKS_CLUSTER_NAME:-azure-documentdb}" --overwrite-existing
      aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME:-aws-documentdb}" --region "$EKS_REGION"
    else
      echo "Multi-cloud stack not found. Deploying (~25-35 min)..."
      bash "$REPO_ROOT/infra/multi-cloud/deploy.sh"
      echo ""
      echo "Now deploying DocumentDB across the mesh..."
      DELETE_EXISTING=true bash "$REPO_ROOT/infra/multi-cloud/deploy-documentdb.sh"
    fi
    echo ""
    echo "✅ Multi-cloud ready. Contexts:"
    echo "  hub                    (Fleet hub)"
    echo "  azure-documentdb       (AKS member)"
    echo "  aws-documentdb         (EKS member)"
    echo ""
    echo "Status:"
    kubectl --context hub get clusterresourceplacement 2>/dev/null || true
    ;;
  4)
    echo ""
    echo "=== Starting local DocumentDB ==="
    docker start docdb 2>/dev/null || {
      echo "Container not found. Creating..."
      docker pull ghcr.io/documentdb/documentdb/documentdb-local:latest
      docker run -dt -p 10260:10260 --name docdb \
        ghcr.io/documentdb/documentdb/documentdb-local:latest \
        --username demo --password test
    }
    echo "✅ DocumentDB local running on port 10260"
    echo "Connect: mongosh \"mongodb://demo:test@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true\""
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
