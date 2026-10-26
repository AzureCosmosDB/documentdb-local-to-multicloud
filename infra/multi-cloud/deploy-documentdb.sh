#!/usr/bin/env bash
# Deploy the DocumentDB CR via the Fleet hub. Adapted from upstream
# documentdb-playground/multi-cloud-deployment/deploy-documentdb.sh
#
# Differences from upstream:
#   - AKS is the default primary (CLUSTER_ARRAY[0])
#   - GKE is opt-in via INCLUDE_GKE=true
#   - DELETE_EXISTING=true skips the interactive prompt and force-deletes
#   - ENABLE_AZURE_DNS defaults to false (DNS zone work is rarely needed for the demo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRIMARY_EXPLICIT="${PRIMARY_CLUSTER:+true}"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/../versions.sh"
DELETE_EXISTING="${DELETE_EXISTING:-false}"
ENABLE_AZURE_DNS="${ENABLE_AZURE_DNS:-false}"

AZURE_DNS_ZONE_NAME="${AZURE_DNS_ZONE_NAME:-${RESOURCE_GROUP}}"
AZURE_DNS_PARENT_ZONE_RESOURCE_ID="${AZURE_DNS_PARENT_ZONE_RESOURCE_ID:-}"
AZURE_DNS_ZONE_FULL_NAME="${AZURE_DNS_ZONE_FULL_NAME:-}"
AZURE_DNS_ZONE_RG="${AZURE_DNS_ZONE_RG:-${RESOURCE_GROUP}}"

RENDER_ONLY=false
if [ "${1:-}" = "--render" ]; then RENDER_ONLY=true; shift; fi
DOCUMENTDB_PASSWORD="${1:-${DOCUMENTDB_PASSWORD:-}}"
if [ "$RENDER_ONLY" = false ] && kubectl --context "$HUB_CONTEXT" -n documentdb-preview-ns get secret documentdb-credentials >/dev/null 2>&1; then
  DOCUMENTDB_PASSWORD=$(kubectl --context "$HUB_CONTEXT" -n documentdb-preview-ns get secret documentdb-credentials -o jsonpath='{.data.password}' | base64 -d)
fi
if [ -z "$DOCUMENTDB_PASSWORD" ]; then
  if [ "$RENDER_ONLY" = true ]; then
    echo "ERROR: set DOCUMENTDB_PASSWORD for offline rendering (use a dummy value)." >&2
    exit 1
  fi
  echo "No password provided; generating one. Stored in the Kubernetes Secret."
  DOCUMENTDB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
fi
export DOCUMENTDB_PASSWORD

CLUSTER_ARRAY=("${MEMBER_CLUSTER_NAMES[@]}")

CLUSTER_LIST=""
PLACEMENT_LIST=""
for i in "${!CLUSTER_ARRAY[@]}"; do
  CLUSTER_LIST+="      - name: ${CLUSTER_ARRAY[$i]}
        environment: ${MEMBER_ENVIRONMENTS[$i]}
"
  if [ "${MEMBER_ENVIRONMENTS[$i]}" = eks ]; then
    CLUSTER_LIST+="        storageClass: documentdb-storage
"
  fi
  PLACEMENT_LIST+="      - ${CLUSTER_ARRAY[$i]}
"
done

render_manifest() {
  local line password_b64
  password_b64=$(printf '%s' "$DOCUMENTDB_PASSWORD" | base64 | tr -d '\r\n')
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    case "$line" in
      '{{CLUSTER_LIST}}') printf '%s' "$CLUSTER_LIST" ;;
      '{{PLACEMENT_LIST}}') printf '%s' "$PLACEMENT_LIST" ;;
      *)
        line="${line//\{\{DOCUMENTDB_PASSWORD_BASE64\}\}/$password_b64}"
        line="${line//\{\{PRIMARY_CLUSTER\}\}/$PRIMARY_CLUSTER}"
        line="${line//\{\{DOCUMENTDB_VERSION\}\}/$DOCUMENTDB_VERSION}"
        printf '%s\n' "$line"
        ;;
    esac
  done < "$SCRIPT_DIR/documentdb-cluster.yaml"
}
if [ "$RENDER_ONLY" = true ]; then render_manifest; exit 0; fi
echo "Member clusters (${#CLUSTER_ARRAY[@]}): ${CLUSTER_ARRAY[*]}"
echo "Primary cluster: $PRIMARY_CLUSTER"
echo "Hub context:     $HUB_CONTEXT"

echo ""
echo "=== Creating cluster-name ConfigMaps on members ==="
for cluster in "${CLUSTER_ARRAY[@]}"; do
  if ! kubectl config get-contexts "$cluster" >/dev/null 2>&1; then
    echo "ERROR: context $cluster not found. Run deploy.sh first." >&2
    exit 1
  fi
  kubectl --context "$cluster" create configmap cluster-name \
    -n kube-system --from-literal=name="$cluster" \
    --dry-run=client -o yaml | kubectl --context "$cluster" apply -f -
  echo "  OK $cluster"
done

if ! kubectl config get-contexts "$HUB_CONTEXT" >/dev/null 2>&1; then
  echo "ERROR: hub context '$HUB_CONTEXT' not found. Run deploy.sh first." >&2
  exit 1
fi

EXISTING_RESOURCES=""
kubectl --context "$HUB_CONTEXT" get namespace documentdb-preview-ns >/dev/null 2>&1 && EXISTING_RESOURCES+="namespace "
kubectl --context "$HUB_CONTEXT" get secret documentdb-credentials -n documentdb-preview-ns >/dev/null 2>&1 && EXISTING_RESOURCES+="secret "
kubectl --context "$HUB_CONTEXT" get documentdb documentdb-preview -n documentdb-preview-ns >/dev/null 2>&1 && EXISTING_RESOURCES+="documentdb "
kubectl --context "$HUB_CONTEXT" get clusterresourceplacement documentdb-crp >/dev/null 2>&1 && EXISTING_RESOURCES+="clusterresourceplacement "

if [ -n "$EXISTING_RESOURCES" ]; then
  echo ""
  echo "WARN: Existing resources detected: $EXISTING_RESOURCES"
  if [ "$DELETE_EXISTING" = "true" ]; then
    CHOICE=1
  else
    echo "  1) Delete and redeploy"
    echo "  2) Update in place (preserve data)"
    echo "  3) Cancel"
    read -rp "Choose (1/2/3): " CHOICE
  fi
  case "$CHOICE" in
    1)
      echo "Deleting existing resources..."
      kubectl --context "$HUB_CONTEXT" delete clusterresourceplacement documentdb-crp --ignore-not-found=true
      kubectl --context "$HUB_CONTEXT" delete namespace documentdb-preview-ns --ignore-not-found=true
      for c in "${CLUSTER_ARRAY[@]}"; do
        kubectl --context "$c" wait --for=delete namespace/documentdb-preview-ns --timeout=120s 2>/dev/null || true
      done
      ;;
    2)
      current=$(kubectl --context "$HUB_CONTEXT" -n documentdb-preview-ns get documentdb documentdb-preview -o json)
      current_version=$(printf '%s' "$current" | jq -r '.spec.documentDBVersion // ""')
      if [ "$current_version" != "$DOCUMENTDB_VERSION" ]; then
        echo "ERROR: existing engine is '$current_version', requested '$DOCUMENTDB_VERSION'. Follow the upstream upgrade guide before using this script." >&2
        exit 1
      fi
      existing_primary=$(printf '%s' "$current" | jq -r '.spec.clusterReplication.primary')
      if [[ " ${CLUSTER_ARRAY[*]} " != *" $existing_primary "* ]]; then
        echo "ERROR: the current primary is not an enabled member; promote another member before removing it." >&2
        exit 1
      fi
      if [ "$PRIMARY_EXPLICIT" = true ] && [ "$PRIMARY_CLUSTER" != "$existing_primary" ]; then
        echo "ERROR: use the promote workflow to change an existing primary, not a deployment update." >&2
        exit 1
      fi
      PRIMARY_CLUSTER="$existing_primary"
      echo "Updating in place; primary: $PRIMARY_CLUSTER"
      ;;
    3) echo "Cancelled."; exit 0 ;;
    *) echo "Invalid choice."; exit 1 ;;
  esac
fi

TEMP_YAML=$(mktemp)
chmod 600 "$TEMP_YAML"
trap 'rm -f "$TEMP_YAML"' EXIT
render_manifest > "$TEMP_YAML"

echo ""
echo "=== Generated DocumentDB CR ==="
echo "Primary: $PRIMARY_CLUSTER"
echo "Cluster list:"
echo "$CLUSTER_LIST"
echo ""

kubectl --context "$HUB_CONTEXT" apply -f "$TEMP_YAML"
rm -f "$TEMP_YAML"

echo ""
echo "ClusterResourcePlacement status:"
kubectl --context "$HUB_CONTEXT" get clusterresourceplacement documentdb-crp -o wide || true

echo ""
echo "Waiting 10s for propagation..."
sleep 10

echo ""
echo "=== Per-member status ==="
for cluster in "${CLUSTER_ARRAY[@]}"; do
  echo ""
  echo "--- $cluster ---"
  if ! kubectl config get-contexts "$cluster" >/dev/null 2>&1; then
    echo "  X context not found"
    continue
  fi
  CID=$(kubectl --context "$cluster" get configmap cluster-name -n kube-system -o jsonpath='{.data.name}' 2>/dev/null || echo "?")
  echo "  cluster-name configmap: $CID"
  if kubectl --context "$cluster" get namespace documentdb-preview-ns >/dev/null 2>&1; then
    kubectl --context "$cluster" get secret documentdb-credentials -n documentdb-preview-ns >/dev/null 2>&1 \
      && echo "  OK secret" || echo "  X secret"
    if kubectl --context "$cluster" get documentdb documentdb-preview -n documentdb-preview-ns >/dev/null 2>&1; then
      STATUS=$(kubectl --context "$cluster" get documentdb documentdb-preview -n documentdb-preview-ns -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      ROLE="REPLICA"
      [ "$cluster" = "$PRIMARY_CLUSTER" ] && ROLE="PRIMARY"
      echo "  OK DocumentDB CR (status=$STATUS, role=$ROLE)"
    else
      echo "  X DocumentDB CR (still propagating?)"
    fi
    PODS=$(kubectl --context "$cluster" get pods -n documentdb-preview-ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  pods: $PODS"
    [ "$PODS" -gt 0 ] && kubectl --context "$cluster" get pods -n documentdb-preview-ns 2>/dev/null | head -5
  else
    echo "  X namespace not present yet"
  fi
done

if [ "$ENABLE_AZURE_DNS" = "true" ]; then
  echo ""
  echo "=== Configuring Azure DNS records ==="
  if [ -n "$AZURE_DNS_ZONE_FULL_NAME" ]; then
    fullName="$AZURE_DNS_ZONE_FULL_NAME"
  else
    parentName=$(az network dns zone show --id "$AZURE_DNS_PARENT_ZONE_RESOURCE_ID" | jq -r ".name")
    fullName="${AZURE_DNS_ZONE_NAME}.${parentName}"
    if ! az network dns zone show --name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" >/dev/null 2>&1; then
      az network dns zone create --name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --parent-name "$AZURE_DNS_PARENT_ZONE_RESOURCE_ID"
    fi
  fi
  echo "Waiting 30s for DocumentDB services to come up..."
  sleep 30
  for cluster in "${CLUSTER_ARRAY[@]}"; do
    SERVICE_NAME="documentdb-service-documentdb-preview"
    SERVICE_NAME="${SERVICE_NAME:0:63}"
    EXTERNAL_IP=""
    EXTERNAL_HOSTNAME=""
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
      EXTERNAL_IP=$(kubectl --context "$cluster" get svc "$SERVICE_NAME" -n documentdb-preview-ns -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      EXTERNAL_HOSTNAME=$(kubectl --context "$cluster" get svc "$SERVICE_NAME" -n documentdb-preview-ns -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
      [ -n "$EXTERNAL_IP$EXTERNAL_HOSTNAME" ] && break
      echo "  Waiting on $cluster ($attempt/12)..."
      sleep 10
    done
    if [ -n "$EXTERNAL_IP" ]; then
      az network dns record-set a    delete --name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --yes 2>/dev/null || true
      az network dns record-set a    create --name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --ttl 5
      az network dns record-set a    add-record --record-set-name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --ipv4-address "$EXTERNAL_IP" --ttl 5
      echo "  OK A record $cluster -> $EXTERNAL_IP"
    elif [ -n "$EXTERNAL_HOSTNAME" ]; then
      az network dns record-set cname delete --name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --yes 2>/dev/null || true
      az network dns record-set cname create --name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --ttl 5
      az network dns record-set cname set-record --record-set-name "$cluster" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --cname "$EXTERNAL_HOSTNAME" --ttl 5
      echo "  OK CNAME $cluster -> $EXTERNAL_HOSTNAME"
    else
      echo "  X no external IP/hostname for $cluster"
    fi
  done
  az network dns record-set srv delete --name "_mongodb._tcp" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --yes 2>/dev/null || true
  az network dns record-set srv create --name "_mongodb._tcp" --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" --ttl 5
  mongoFQDN=$(az network dns record-set srv add-record --record-set-name "_mongodb._tcp" \
    --zone-name "$fullName" --resource-group "$AZURE_DNS_ZONE_RG" \
    --priority 0 --weight 0 --port 10260 --target "$PRIMARY_CLUSTER.$fullName" | jq -r ".fqdn")
  echo "OK DNS zone $fullName ready (mongo FQDN: $mongoFQDN)"
fi

echo ""
echo "============================================================"
echo "DocumentDB CR applied."
echo ""
echo "Connection info:"
echo "  Username: docdb"
echo "  Password: stored in Secret documentdb-credentials (not printed)"
echo ""
echo "Next: load the demo dataset onto the primary (replicates to the"
echo "replica cloud over WAL). From the repo root:"
echo "  Windows:  .\\load-data.bat"
echo "  Linux:    MONGODB_URI='<primary URI>' bash data/load-data.sh"
echo ""
echo "Watch CRP propagation:"
echo "  watch 'kubectl --context $HUB_CONTEXT get clusterresourceplacement documentdb-crp -o wide'"
echo ""
echo "Per-member status:"
CLUSTER_STRING=$(IFS=' '; echo "${CLUSTER_ARRAY[*]}")
echo "  for c in $CLUSTER_STRING; do echo \"=== \$c ===\"; kubectl --context \$c get documentdb,pods -n documentdb-preview-ns 2>/dev/null; echo; done"
echo "============================================================"
