#!/bin/bash
# Cleanup AWS EKS resources for the DocumentDB demo.
#
# Use this to tear down everything created by infra/aws/deploy.sh.
# By default it prompts for confirmation; pass --yes (or -y) to skip.
#
# Removes (in order):
#   1. DocumentDB CR + namespace      (releases the NLB)
#   2. DocumentDB operator helm chart
#   3. cert-manager
#   4. EKS cluster (eksctl delete cluster, ~10-12 min)
#
# Safe to re-run; each step skips if the resource is already gone.

set -uo pipefail

# --- Cross-platform tool discovery (matches deploy.sh) ---
if [[ "$(uname -s)" == *MINGW* ]] || [[ "$(uname -s)" == *MSYS* ]] || [[ "$(uname -s)" == *CYGWIN* ]] || grep -qi microsoft /proc/version 2>/dev/null; then
  WIN_ROOTS=("/c" "/mnt/c")
  WIN_DIRS=(
    "ProgramData/chocolatey/bin"
    "Program Files/Docker/Docker/resources/bin"
    "Program Files/Amazon/AWSCLIV2"
  )
  for root in "${WIN_ROOTS[@]}"; do
    for dir in "${WIN_DIRS[@]}"; do
      [[ -d "$root/$dir" ]] && export PATH="$PATH:$root/$dir"
    done
  done
  for p in "$HOME/tools" "$HOME/bin" "$HOME/scoop/shims"; do
    [[ -d "$p" ]] && export PATH="$PATH:$p"
  done
fi
for cmd in aws kubectl helm eksctl; do
  if ! command -v "$cmd" &>/dev/null && command -v "${cmd}.exe" &>/dev/null; then
    eval "function $cmd() { ${cmd}.exe \"\$@\"; }"
    export -f "$cmd" 2>/dev/null || true
  fi
done

CLUSTER_NAME="${EKS_CLUSTER_NAME:-docdb-demo-eks}"
REGION="${EKS_REGION:-us-west-2}"

ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
  esac
done

echo "=== EKS cleanup ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region:  $REGION"
echo ""

if [[ "$ASSUME_YES" != true ]]; then
  echo "This will DELETE the EKS cluster and all DocumentDB data on it."
  read -rp "Type 'delete' to confirm: " confirm
  [[ "$confirm" == "delete" ]] || { echo "Cancelled."; exit 1; }
fi

# Set kubectl context (best-effort; cluster may already be gone)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias eks-demo >/dev/null 2>&1 || true

echo ""
echo "[1/4] Deleting DocumentDB instance + namespace (releases NLB) ..."
kubectl delete namespace documentdb-ns --ignore-not-found --timeout=180s 2>/dev/null || true

echo "[2/4] Uninstalling DocumentDB operator helm release ..."
helm uninstall documentdb-operator --namespace documentdb-operator 2>/dev/null || true
kubectl delete namespace documentdb-operator --ignore-not-found --timeout=120s 2>/dev/null || true

echo "[3/4] Removing cert-manager ..."
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found 2>/dev/null || true

echo "[4/4] Deleting EKS cluster (eksctl, ~10-12 min) ..."
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
else
  echo "Cluster already deleted."
fi

echo ""
echo "=== Cleanup complete. No further AWS charges for this demo. ==="
echo ""
echo "Verify nothing is left:"
echo "  aws cloudformation list-stacks --region $REGION --query \"StackSummaries[?contains(StackName,'docdb')]\""
echo "  aws ec2 describe-volumes --region $REGION --filters Name=tag:project,Values=documentdb-local-to-multicloud"
