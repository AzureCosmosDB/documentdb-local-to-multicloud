#!/bin/bash
# Cleanup AKS resources for the DocumentDB demo.
#
# Use this to tear down everything created by infra/azure/deploy.sh.
# By default it prompts for confirmation; pass --yes (or -y) to skip.
#
# Removes (in order):
#   1. DocumentDB CR + namespace      (releases the LoadBalancer)
#   2. DocumentDB operator helm chart
#   3. cert-manager
#   4. The entire resource group     (deletes AKS, disks, NICs, IPs, etc.)
#
# Safe to re-run; each step skips if the resource is already gone.

set -uo pipefail

# --- Cross-platform tool discovery (matches deploy.sh) ---
if [[ "$(uname -s)" == *MINGW* ]] || [[ "$(uname -s)" == *MSYS* ]] || [[ "$(uname -s)" == *CYGWIN* ]] || grep -qi microsoft /proc/version 2>/dev/null; then
  WIN_ROOTS=("/c" "/mnt/c")
  WIN_DIRS=(
    "ProgramData/chocolatey/bin"
    "Program Files/Docker/Docker/resources/bin"
    "Program Files/Microsoft SDKs/Azure/CLI2/wbin"
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
for cmd in az kubectl helm; do
  if ! command -v "$cmd" &>/dev/null && command -v "${cmd}.exe" &>/dev/null; then
    eval "function $cmd() { ${cmd}.exe \"\$@\"; }"
    export -f "$cmd" 2>/dev/null || true
  fi
done

RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-demo-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-docdb-demo-aks}"

ASSUME_YES=false
WAIT=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=true ;;
    --wait)    WAIT=true ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  esac
done

echo "=== AKS cleanup ==="
echo "Resource group: $RESOURCE_GROUP"
echo "Cluster:        $CLUSTER_NAME"
echo ""

if [[ "$ASSUME_YES" != true ]]; then
  echo "This will DELETE the resource group '$RESOURCE_GROUP' and all DocumentDB data on it."
  read -rp "Type 'delete' to confirm: " confirm
  [[ "$confirm" == "delete" ]] || { echo "Cancelled."; exit 1; }
fi

# Best-effort: get credentials so we can drop the LB cleanly first
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing --context aks-demo >/dev/null 2>&1 || true

echo ""
echo "[1/4] Deleting DocumentDB instance + namespace (releases LoadBalancer) ..."
kubectl delete namespace documentdb-ns --ignore-not-found --timeout=180s 2>/dev/null || true

echo "[2/4] Uninstalling DocumentDB operator helm release ..."
helm uninstall documentdb-operator --namespace documentdb-operator 2>/dev/null || true
kubectl delete namespace documentdb-operator --ignore-not-found --timeout=120s 2>/dev/null || true

echo "[3/4] Removing cert-manager ..."
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found 2>/dev/null || true

echo "[4/4] Deleting resource group $RESOURCE_GROUP ..."
if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
  if [[ "$WAIT" == true ]]; then
    az group delete --name "$RESOURCE_GROUP" --yes
  else
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    echo "(Delete running async. Pass --wait to block until complete.)"
  fi
else
  echo "Resource group already deleted."
fi

echo ""
echo "=== Cleanup initiated. ==="
echo ""
echo "Verify:"
echo "  az group exists --name $RESOURCE_GROUP"
