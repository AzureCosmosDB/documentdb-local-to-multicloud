#!/bin/bash
# Stop demo infrastructure - save costs when not rehearsing.
#
# The multi-cloud stack (Fleet + AKS + EKS + Istio) cannot be partially stopped
# in a useful way — Fleet membership, Istio mesh, and CNPG WAL replication all
# expect both members up. So "stop" here means tear it all down via
# infra/multi-cloud/cleanup.sh and redeploy on demo day.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "============================================"
echo "  DocumentDB Demo Infrastructure - STOP"
echo "============================================"
echo ""
echo "Choose what to stop:"
echo "  1) Local only (stop Docker container)"
echo "  2) Multi-cloud (DESTROY: AKS + EKS + Fleet + RG)"
echo "  3) Show status only"
read -rp "Selection [1-3]: " choice

case $choice in
  1)
    echo "=== Stopping local DocumentDB ==="
    docker compose -f "$REPO_ROOT/docker-compose.yml" stop documentdb
    ;;
  2)
    # The shared cleanup script prints the configured members and asks for confirmation.
    bash "$REPO_ROOT/infra/multi-cloud/cleanup.sh" --wait
    ;;
  3)
    source "$REPO_ROOT/infra/multi-cloud/config.sh"
    echo "=== Local ==="
    docker ps --filter name=docdb --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
    echo ""
    echo "=== Azure ==="
    az group exists --name "$RESOURCE_GROUP"
    echo ""
    if [ "$INCLUDE_EKS" = true ]; then
      echo "=== AWS ($EKS_REGION) ==="
      aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" --query cluster.status --output text
    fi
    ;;
  *)
    echo "Invalid selection"
    exit 1
    ;;
esac

echo ""
echo "💰 Cost reminder:"
echo "   Local Docker:  free"
echo "   Multi-cloud:   ~\$13/day running (~\$390/mo if left up)"
