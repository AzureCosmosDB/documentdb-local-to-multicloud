#!/bin/bash
# Deploy AKS cluster for DocumentDB demo
set -euo pipefail

# --- Cross-platform tool discovery ---
# On Windows (Git Bash, WSL, MSYS), tools may not be on PATH.
# Search common locations with both /c/ and /mnt/c/ prefixes.
if [[ "$(uname -s)" == *MINGW* ]] || [[ "$(uname -s)" == *MSYS* ]] || [[ "$(uname -s)" == *CYGWIN* ]] || grep -qi microsoft /proc/version 2>/dev/null; then
  WIN_ROOTS=("/c" "/mnt/c")
  WIN_DIRS=(
    "ProgramData/chocolatey/bin"
    "Program Files/Docker/Docker/resources/bin"
    "Program Files/Amazon/AWSCLIV2"
    "Program Files/Microsoft SDKs/Azure/CLI2/wbin"
  )
  for root in "${WIN_ROOTS[@]}"; do
    for dir in "${WIN_DIRS[@]}"; do
      [[ -d "$root/$dir" ]] && export PATH="$PATH:$root/$dir"
    done
  done
  # User-local paths
  for p in "$HOME/tools" "$HOME/bin" "$HOME/scoop/shims" "$HOME/AppData/Local/Programs/mongosh"; do
    [[ -d "$p" ]] && export PATH="$PATH:$p"
  done
fi

# Verify required tools (check both 'cmd' and 'cmd.exe' for WSL compatibility)
for cmd in az kubectl helm; do
  if ! command -v "$cmd" &>/dev/null && ! command -v "${cmd}.exe" &>/dev/null; then
    echo "ERROR: Required tool not found: $cmd"
    echo "   Install it and ensure it is on your PATH."
    echo "   See SETUP.md for installation links."
    exit 1
  fi
done
echo "All required tools found."

# WSL shim: if 'helm' isn't found but 'helm.exe' is, create aliases
for cmd in az kubectl helm mongosh; do
  if ! command -v "$cmd" &>/dev/null && command -v "${cmd}.exe" &>/dev/null; then
    eval "function $cmd() { ${cmd}.exe \"\$@\"; }"
    export -f "$cmd" 2>/dev/null || true
  fi
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-demo-rg}"
LOCATION="${LOCATION:-eastus2}"
CLUSTER_NAME="${CLUSTER_NAME:-docdb-demo-aks}"

# Get owner email from signed-in user
OWNER_EMAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || echo "unknown")
echo "Owner: $OWNER_EMAIL"

echo "=== Deploying AKS cluster ==="
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Cluster: $CLUSTER_NAME"

# Create resource group with owner tag (idempotent)
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --tags owner="$OWNER_EMAIL" project=documentdb-local-to-multicloud --output none

# Deploy Bicep template (idempotent — ARM is declarative; skips if no drift)
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters "$(dirname "$0")/main.bicepparam" \
  --parameters clusterName="$CLUSTER_NAME" location="$LOCATION" ownerEmail="$OWNER_EMAIL" \
  --output none

# Get credentials
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing --context aks-demo

echo ""
echo "=== Installing DocumentDB operator ==="

# Install cert-manager (idempotent via apply)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
echo "Waiting for cert-manager..."
kubectl wait --for=condition=available --timeout=180s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=180s deployment/cert-manager-webhook -n cert-manager

# Install DocumentDB operator via Helm (idempotent via upgrade --install)
helm repo add documentdb https://documentdb.github.io/documentdb-kubernetes-operator 2>/dev/null || true
helm repo update
helm upgrade --install documentdb-operator documentdb/documentdb-operator \
  --namespace documentdb-operator --create-namespace

echo "Waiting for operator..."
kubectl wait --for=condition=available --timeout=180s deployment/documentdb-operator -n documentdb-operator

echo ""
echo "=== Deploying DocumentDB instance ==="

# Persist password across re-runs in a Secret on first deploy.
kubectl create namespace documentdb-ns --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret docdb-demo-credentials -n documentdb-ns >/dev/null 2>&1; then
  DOCDB_PASSWORD="$(kubectl get secret docdb-demo-credentials -n documentdb-ns -o jsonpath='{.data.password}' | base64 -d)"
  echo "Reusing existing DocumentDB credentials from Secret docdb-demo-credentials."
else
  DOCDB_PASSWORD="${DOCDB_PASSWORD:-$(openssl rand -hex 16)}"
  kubectl create secret generic docdb-demo-credentials \
    --namespace documentdb-ns \
    --from-literal=username=docdb \
    --from-literal=password="$DOCDB_PASSWORD"
fi

cat <<EOF | kubectl apply -f -
apiVersion: documentdb.io/preview
kind: DocumentDB
metadata:
  name: docdb-demo
  namespace: documentdb-ns
spec:
  environment: aks
  nodeCount: 1
  instancesPerNode: 1
  documentDbCredentialSecret: docdb-demo-credentials
  resource:
    storage:
      pvcSize: 20Gi
  exposeViaService:
    serviceType: LoadBalancer
EOF

echo ""
echo "=== AKS deployment complete ==="
echo "Password: $DOCDB_PASSWORD"
echo ""
echo "Waiting for LoadBalancer IP..."
for i in {1..60}; do
  EXTERNAL_IP=$(kubectl get svc -n documentdb-ns -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "LoadBalancer IP: $EXTERNAL_IP"
    break
  fi
  echo "  Waiting... ($i/60)"
  sleep 10
done

if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
  AKS_URI="mongodb://docdb:${DOCDB_PASSWORD}@${EXTERNAL_IP}:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256"

  echo ""
  echo "=== Loading demo data ==="
  MONGODB_URI="$AKS_URI" bash "$REPO_ROOT/data/load-data.sh"

  echo ""
  echo "=== Wiping indexes (ready for Index Advisor demo) ==="
  MONGODB_URI="$AKS_URI" bash "$REPO_ROOT/data/wipe-data.sh" --indexes

  echo ""
  echo "Connect:"
  echo "  mongosh \"$AKS_URI\""
else
  echo "⚠️  LoadBalancer IP not ready. Load data manually after IP is assigned."
  echo "  MONGODB_URI=\"mongodb://docdb:\$PASSWORD@<IP>:10260/...\" bash data/load-data.sh"
fi
