#!/bin/bash
# Deploy EKS cluster for DocumentDB demo
set -euo pipefail

# --- Cross-platform tool discovery ---
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

# Verify required tools (check both 'cmd' and 'cmd.exe' for WSL compatibility)
for cmd in aws kubectl helm eksctl; do
  if ! command -v "$cmd" &>/dev/null && ! command -v "${cmd}.exe" &>/dev/null; then
    echo "ERROR: Required tool not found: $cmd"
    echo "   Install it and ensure it is on your PATH."
    echo "   See SETUP.md for installation links."
    exit 1
  fi
done
echo "All required tools found."
# WSL shim: if 'cmd' isn't found but 'cmd.exe' is, create aliases
for cmd in aws kubectl helm eksctl mongosh; do
  if ! command -v "$cmd" &>/dev/null && command -v "${cmd}.exe" &>/dev/null; then
    eval "function $cmd() { ${cmd}.exe \"\$@\"; }"
    export -f "$cmd" 2>/dev/null || true
  fi
done

CLUSTER_NAME="${EKS_CLUSTER_NAME:-docdb-demo-eks}"
REGION="${EKS_REGION:-us-west-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Convert a POSIX path to a path the host OS Windows binaries can read.
# Under WSL, eksctl.exe (and other Windows-native binaries) cannot resolve
# /mnt/c/... paths and need C:\... form. Git Bash / MSYS already use /c/...
# which Windows binaries handle natively, so no conversion is needed there.
to_winpath() {
  if grep -qi microsoft /proc/version 2>/dev/null && command -v wslpath &>/dev/null; then
    wslpath -w "$1"
  else
    echo "$1"
  fi
}

# Get owner identity for tagging
OWNER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | sed 's|.*/||' || echo "unknown")
echo "Owner: $OWNER"

echo "=== Deploying EKS cluster ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"

# Create EKS cluster using eksctl (tags are defined in cluster-config.yaml metadata)
# Idempotent: skip cluster creation if it already exists.
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "EKS cluster '$CLUSTER_NAME' already exists in $REGION — skipping create."
else
  eksctl create cluster -f "$(to_winpath "$SCRIPT_DIR/cluster-config.yaml")"
fi

# Update kubeconfig (always, in case context isn't set)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias eks-demo

# Create gp3 storage class (idempotent via apply)
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: documentdb-storage
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

echo ""
echo "=== Installing DocumentDB operator ==="

# Install cert-manager (idempotent via apply)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
echo "Waiting for cert-manager..."
kubectl wait --for=condition=available --timeout=180s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=180s deployment/cert-manager-webhook -n cert-manager

# Install DocumentDB operator (helm upgrade --install for idempotency)
helm repo add documentdb https://documentdb.github.io/documentdb-kubernetes-operator 2>/dev/null || true
helm repo update
helm upgrade --install documentdb-operator documentdb/documentdb-operator \
  --namespace documentdb-operator --create-namespace

echo "Waiting for operator..."
kubectl wait --for=condition=available --timeout=180s deployment/documentdb-operator -n documentdb-operator

echo ""
echo "=== Deploying DocumentDB instance ==="

# Persist password across re-runs: store in a Secret on first deploy, reuse on subsequent runs.
# Secret must have keys 'username' and 'password' for the DocumentDB operator.
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
  environment: eks
  nodeCount: 1
  instancesPerNode: 1
  documentDbCredentialSecret: docdb-demo-credentials
  resource:
    storage:
      pvcSize: 20Gi
      storageClass: documentdb-storage
  exposeViaService:
    serviceType: LoadBalancer
EOF

# Patch the Service to use AWS NLB (operator no longer supports serviceAnnotations).
# The Service is created by the operator; wait briefly and then annotate.
echo "Waiting for DocumentDB Service to be created..."
for i in {1..30}; do
  SVC_NAME=$(kubectl get svc -n documentdb-ns -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}' 2>/dev/null | awk '{print $1}')
  if [ -n "$SVC_NAME" ]; then
    kubectl annotate svc -n documentdb-ns "$SVC_NAME" \
      service.beta.kubernetes.io/aws-load-balancer-type=nlb \
      service.beta.kubernetes.io/aws-load-balancer-scheme=internet-facing \
      --overwrite
    echo "Annotated Service '$SVC_NAME' for NLB."
    break
  fi
  sleep 5
done

echo ""
echo "=== EKS deployment complete ==="
echo "Password: $DOCDB_PASSWORD"
echo ""
echo "Waiting for NLB hostname (2-5 min)..."
for i in {1..60}; do
  NLB_HOST=$(kubectl get svc -n documentdb-ns -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$NLB_HOST" ] && [ "$NLB_HOST" != "null" ]; then
    echo "NLB hostname: $NLB_HOST"
    break
  fi
  echo "  Waiting... ($i/60)"
  sleep 10
done

if [ -n "$NLB_HOST" ] && [ "$NLB_HOST" != "null" ]; then
  EKS_URI="mongodb://docdb:${DOCDB_PASSWORD}@${NLB_HOST}:10260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256"

  echo ""
  echo "=== Loading demo data ==="
  MONGODB_URI="$EKS_URI" bash "$REPO_ROOT/data/load-data.sh"

  echo ""
  echo "=== Wiping indexes (ready for Index Advisor demo) ==="
  MONGODB_URI="$EKS_URI" bash "$REPO_ROOT/data/wipe-data.sh" --indexes

  echo ""
  echo "Connect:"
  echo "  mongosh \"$EKS_URI\""
else
  echo "⚠️  NLB not ready. Load data manually after hostname is assigned."
  echo "  MONGODB_URI=\"mongodb://docdb:\$PASSWORD@<HOST>:10260/...\" bash data/load-data.sh"
fi
