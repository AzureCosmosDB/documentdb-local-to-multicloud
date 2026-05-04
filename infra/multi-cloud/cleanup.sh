#!/usr/bin/env bash
# Tear down the multi-cloud DocumentDB stack.
# Flags: -y (no confirm), --wait (block until Azure RG and EKS deletion complete).

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-multicloud-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-azure-documentdb}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-aws-documentdb}"
EKS_REGION="${EKS_REGION:-us-west-2}"
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-gcp-documentdb}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-${PROJECT_ID:-}}"
GCP_ZONE="${GCP_ZONE:-${ZONE:-us-central1-a}}"
INCLUDE_GKE="${INCLUDE_GKE:-false}"
HUB_CONTEXT="${HUB_CONTEXT:-hub}"

YES=false
WAIT=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    --wait)   WAIT=true ;;
  esac
done

echo "Multi-cloud cleanup target:"
echo "  Azure RG:   $RESOURCE_GROUP"
echo "  EKS:        $EKS_CLUSTER_NAME (region $EKS_REGION)"
[ "$INCLUDE_GKE" = "true" ] && echo "  GKE:        $GKE_CLUSTER_NAME (project $GCP_PROJECT_ID, zone $GCP_ZONE)"

if [ "$YES" != "true" ]; then
  read -rp "Type 'destroy' to confirm: " confirm
  [ "$confirm" = "destroy" ] || { echo "Cancelled."; exit 0; }
fi

if kubectl config get-contexts "$HUB_CONTEXT" >/dev/null 2>&1; then
  echo "[hub] Removing DocumentDB CR + CRP..."
  kubectl --context "$HUB_CONTEXT" delete clusterresourceplacement documentdb-crp --ignore-not-found=true || true
  kubectl --context "$HUB_CONTEXT" delete namespace documentdb-preview-ns --ignore-not-found=true --wait=false || true
fi

if eksctl get cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" >/dev/null 2>&1; then
  echo "[eks] Deleting cluster $EKS_CLUSTER_NAME (10-15 min)..."
  if [ "$WAIT" = "true" ]; then
    eksctl delete cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" --wait
  else
    eksctl delete cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" --disable-nodegroup-eviction &
  fi
else
  echo "[eks] $EKS_CLUSTER_NAME not present, skipping"
fi

if az group exists --name "$RESOURCE_GROUP" 2>/dev/null | grep -q true; then
  echo "[azure] Deleting RG $RESOURCE_GROUP..."
  if [ "$WAIT" = "true" ]; then
    az group delete --name "$RESOURCE_GROUP" --yes
  else
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
  fi
else
  echo "[azure] RG $RESOURCE_GROUP not present, skipping"
fi

if [ "$INCLUDE_GKE" = "true" ]; then
  if [ -n "$GCP_PROJECT_ID" ] && gcloud container clusters describe "$GKE_CLUSTER_NAME" --zone "$GCP_ZONE" --project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
    echo "[gke] Deleting cluster $GKE_CLUSTER_NAME..."
    gcloud container clusters delete "$GKE_CLUSTER_NAME" --zone "$GCP_ZONE" --project "$GCP_PROJECT_ID" --quiet
  fi
fi

echo "[local] Removing kubectl contexts..."
for ctx in "$HUB_CONTEXT" "$AKS_CLUSTER_NAME" "$EKS_CLUSTER_NAME" "$GKE_CLUSTER_NAME"; do
  kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$ctx" >/dev/null 2>&1 || true
  kubectl config delete-user    "$ctx" >/dev/null 2>&1 || true
done

if [ "$WAIT" = "true" ]; then
  wait 2>/dev/null || true
fi

echo ""
echo "Cleanup initiated. Verify:"
echo "   az group exists --name $RESOURCE_GROUP"
echo "   aws eks list-clusters --region $EKS_REGION"
