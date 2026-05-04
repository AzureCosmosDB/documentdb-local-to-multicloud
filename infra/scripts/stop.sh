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
    docker stop docdb 2>/dev/null && echo "✅ Container stopped" || echo "Container not running"
    ;;
  2)
    echo "⚠️  This deletes the entire multi-cloud stack:"
    echo "   - Azure RG (Fleet hub + AKS member + DNS zones)"
    echo "   - EKS cluster + all CloudFormation stacks"
    echo "   - All DocumentDB data on both clouds"
    echo ""
    read -rp "Type 'destroy' to confirm: " confirm
    if [[ "$confirm" == "destroy" ]]; then
      bash "$REPO_ROOT/infra/multi-cloud/cleanup.sh" -y --wait
      echo "✅ Multi-cloud stack destroyed."
      echo "   Redeploy with: bash infra/multi-cloud/deploy.sh"
    else
      echo "Cancelled."
    fi
    ;;
  3)
    echo "=== Local ==="
    docker ps --filter name=docdb --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
    echo ""
    echo "=== Azure ==="
    az group exists --name docdb-multicloud-rg 2>/dev/null && \
      echo "RG docdb-multicloud-rg: exists" || echo "RG docdb-multicloud-rg: gone"
    echo ""
    echo "=== AWS (us-west-2) ==="
    aws eks list-clusters --region us-west-2 --output text 2>/dev/null || echo "(aws not configured)"
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
