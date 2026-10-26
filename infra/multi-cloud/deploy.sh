#!/usr/bin/env bash
# Multi-cloud DocumentDB deploy: AKS Fleet + Istio multi-cluster mesh + DocumentDB operator.
# Adapted from documentdb-kubernetes-operator/documentdb-playground/multi-cloud-deployment/deploy.sh
#
# Differences from upstream:
#   - AKS + EKS by default; optional regional AKS and GKE members
#   - Resource group defaults to docdb-multicloud-rg (not documentdb-aks-fleet-rg)
#   - Published, pinned operator chart installed independently on each cluster
#
# Env vars:
#   RESOURCE_GROUP        Azure RG (default: docdb-multicloud-rg)
#   RG_LOCATION           Azure region (default: eastus2)
#   AKS_CLUSTER_NAME      default: azure-documentdb
#   EKS_CLUSTER_NAME      default: aws-documentdb
#   EKS_REGION            default: us-west-2
#   GKE_CLUSTER_NAME      default: gcp-documentdb (only used if INCLUDE_GKE=true)
#   INCLUDE_GKE           default: false
#   HUB_CONTEXT           default: hub
#   INCLUDE_EKS           default: true; false for Azure-only deployments
#   INCLUDE_AKS_REPLICA   default: false
#   AKS_REPLICA_REGION    required when INCLUDE_AKS_REPLICA=true

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEMPLATE_DIR/config.sh"
source "$TEMPLATE_DIR/../versions.sh"
HUB_VM_SIZE="${HUB_VM_SIZE:-}"
VALUES_FILE="${VALUES_FILE:-}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-${PROJECT_ID:-}}"
GCP_USER="${GCP_USER:-}"
GCP_ZONE="${GCP_ZONE:-${ZONE:-us-central1-a}}"

run() { echo "+ $*"; "$@"; }

check_prerequisites() {
  echo "Checking prerequisites..."
  local bins=(az kubectl helm jq curl git make kubelogin openssl)
  [ "$INCLUDE_EKS" = true ] && bins+=(aws eksctl)
  for bin in "${bins[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "ERROR: $bin not found on PATH" >&2
      exit 1
    fi
  done
  if [ "$INCLUDE_GKE" = "true" ]; then
    if ! command -v gcloud >/dev/null 2>&1; then
      echo "ERROR: INCLUDE_GKE=true but gcloud CLI not found" >&2
      exit 1
    fi
  fi
  if ! az account show >/dev/null 2>&1; then
    echo "ERROR: not logged into Azure (run 'az login')" >&2
    exit 1
  fi
  if kubectl config get-contexts "$HUB_CONTEXT" >/dev/null 2>&1; then
    legacy=$(kubectl --context "$HUB_CONTEXT" get clusterresourceplacement documentdb-base -o name --ignore-not-found)
    if [ -n "$legacy" ]; then
      echo "ERROR: legacy documentdb-base placement exists. Migrate to a fresh GA stack first (see SETUP.md); no resources have been changed." >&2
      exit 1
    fi
  fi
  if [ "$INCLUDE_EKS" = true ] && ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "ERROR: AWS credentials not configured (run 'aws sso login' or 'aws configure')" >&2
    exit 1
  fi
  # az fleet extension is required for managing AKS Fleet Manager
  if ! az extension show -n fleet >/dev/null 2>&1; then
    echo "Installing missing az extension: fleet"
    az extension add -n fleet --yes >/dev/null 2>&1 || {
      echo "ERROR: failed to install az fleet extension" >&2
      exit 1
    }
  fi
  # Don't prompt to install other extensions interactively
  az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true
  echo "Prerequisites met. Published operator chart: $OPERATOR_VERSION"
}

wait_for_no_inprogress() {
  local rg="$1"
  echo "Checking for in-progress AKS operations in '$rg'..."
  local inprogress
  inprogress=$(az aks list -g "$rg" -o json 2>/dev/null \
    | jq -r '.[] | select(.provisioningState != "Succeeded" and .provisioningState != null) | [.name, .provisioningState] | @tsv' || true)
  if [ -z "$inprogress" ]; then return 0; fi
  echo "Found clusters still provisioning:"
  echo "$inprogress" | while IFS=$'\t' read -r name state; do echo "  - $name: $state"; done
  return 1
}

aks_fleet_deploy() {
  echo "[AKS] Creating/using resource group..."
  EXISTING_RG_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
  if [ -n "$EXISTING_RG_LOCATION" ]; then
    echo "[AKS] Using existing RG '$RESOURCE_GROUP' in '$EXISTING_RG_LOCATION'"
    RG_LOCATION="$EXISTING_RG_LOCATION"
  else
    az group create --name "$RESOURCE_GROUP" --location "$RG_LOCATION" >/dev/null
  fi

  if ! wait_for_no_inprogress "$RESOURCE_GROUP"; then
    echo "[AKS] ERROR: in-progress operations, abort" >&2
    exit 1
  fi

  PARAMS=(
    --parameters "$TEMPLATE_DIR/parameters.bicepparam"
    --parameters hubRegion="$HUB_REGION"
    --parameters memberRegion="$AKS_REGION"
    --parameters memberName="$AKS_CLUSTER_NAME"
    --parameters includeAksReplica="$INCLUDE_AKS_REPLICA"
    --parameters replicaName="$AKS_REPLICA_NAME"
    --parameters replicaRegion="$AKS_REPLICA_REGION"
    --parameters kubernetesVersion="$KUBERNETES_VERSION"
  )
  if [ -n "$HUB_VM_SIZE" ]; then
    PARAMS+=( --parameters hubVmSize="$HUB_VM_SIZE" )
  fi

  DEPLOYMENT_NAME="aks-fleet-$(date +%s)"
  echo "[AKS] Deploying Fleet hub + AKS member via Bicep ($DEPLOYMENT_NAME)..."
  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE_DIR/main.bicep" \
    "${PARAMS[@]}" >/dev/null

  DEPLOYMENT_OUTPUT=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query "properties.outputs" -o json)
  FLEET_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.fleetName.value')
  AKS_CLUSTER_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.memberClusterName.value')

  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  export FLEET_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/fleets/${FLEET_NAME}"

  echo "[AKS] Granting Fleet RBAC to current user..."
  IDENTITY=$(az ad signed-in-user show --query id -o tsv)
  az role assignment create \
    --role "Azure Kubernetes Fleet Manager RBAC Cluster Admin" \
    --assignee "$IDENTITY" \
    --scope "$FLEET_ID" >/dev/null

  echo "[AKS] Fetching Fleet hub + AKS member kubeconfig..."
  az fleet get-credentials --resource-group "$RESOURCE_GROUP" --name "$FLEET_NAME" --overwrite-existing >/dev/null
  for member in "${AKS_MEMBER_NAMES[@]}"; do
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$member" --context "$member" --overwrite-existing >/dev/null
  done
  # Convert AAD-enabled hub kubeconfig to use az CLI tokens (non-interactive)
  if command -v kubelogin >/dev/null 2>&1; then
    kubelogin convert-kubeconfig -l azurecli --context "$HUB_CONTEXT" >/dev/null 2>&1 || true
    for member in "${AKS_MEMBER_NAMES[@]}"; do
      kubelogin convert-kubeconfig -l azurecli --context "$member" >/dev/null
    done
  fi
  echo "[AKS] Fleet hub + member ready (Fleet: $FLEET_NAME, member: $AKS_CLUSTER_NAME)"
}

eks_deploy() {
  NODE_TYPE="m5.large"
  if eksctl get cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" >/dev/null 2>&1; then
    echo "[EKS] Cluster $EKS_CLUSTER_NAME already exists, skipping create"
  else
    echo "[EKS] Creating cluster $EKS_CLUSTER_NAME in $EKS_REGION..."
    eksctl create cluster \
      --name "$EKS_CLUSTER_NAME" \
      --region "$EKS_REGION" \
      --version "$KUBERNETES_VERSION" \
      --node-type "$NODE_TYPE" \
      --nodes 2 --nodes-min 2 --nodes-max 2 \
      --managed --with-oidc
  fi

  # Normalize the EKS kubeconfig context to a short, predictable name
  # so subsequent kubectl/helm calls (which use --context "$EKS_CLUSTER_NAME")
  # work whether eksctl just created the entry or it was created by a prior run.
  clusterName="$EKS_CLUSTER_NAME.$EKS_REGION.eksctl.io"
  fullName="documentdb-admin@$clusterName"
  if [ -f "$HOME/.kube/config" ]; then
    sed -i "s|$fullName|$EKS_CLUSTER_NAME|g" "$HOME/.kube/config" || true
    sed -i "s|$clusterName|$EKS_CLUSTER_NAME|g" "$HOME/.kube/config" || true
  fi
  # Fallback for the ARN-style context name eksctl may write
  arnCtx="arn:aws:eks:$EKS_REGION:$(aws sts get-caller-identity --query Account --output text):cluster/$EKS_CLUSTER_NAME"
  if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$arnCtx"; then
    kubectl config delete-context "$EKS_CLUSTER_NAME" >/dev/null 2>&1 || true
    kubectl config rename-context "$arnCtx" "$EKS_CLUSTER_NAME" >/dev/null
  fi
  # Also handle the user@cluster style name some eksctl versions emit
  for candidate in "$(whoami)@$EKS_CLUSTER_NAME" "${USER:-}@$EKS_CLUSTER_NAME"; do
    [ -z "$candidate" ] || [ "$candidate" = "@$EKS_CLUSTER_NAME" ] && continue
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$candidate"; then
      kubectl config delete-context "$EKS_CLUSTER_NAME" >/dev/null 2>&1 || true
      kubectl config rename-context "$candidate" "$EKS_CLUSTER_NAME" >/dev/null
      break
    fi
  done

  echo "[EKS] Setting up EBS CSI driver..."
  eksctl create iamserviceaccount \
    --cluster "$EKS_CLUSTER_NAME" \
    --namespace kube-system \
    --name ebs-csi-controller-sa \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --override-existing-serviceaccounts --approve --region "$EKS_REGION" >/dev/null
  eksctl create addon \
    --name aws-ebs-csi-driver \
    --cluster "$EKS_CLUSTER_NAME" \
    --region "$EKS_REGION" \
    --force >/dev/null
  sleep 5

  # Pod-to-pod traffic uses the cluster security group only (VPC CNI). Without
  # self-ingress, kube-system (CoreDNS, ebs-csi, metrics-server) crashloops.
  # See docs/upstream-issues.md #4.
  echo "[EKS] Adding security group ingress rules for pod-to-pod traffic..."
  CLUSTER_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" \
    --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
  NODE_SG=$(aws ec2 describe-security-groups --region "$EKS_REGION" \
    --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" \
              "Name=group-name,Values=*nodegroup*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  for SRC in "$CLUSTER_SG" "$NODE_SG"; do
    [ -z "$SRC" ] || [ "$SRC" = "None" ] && continue
    aws ec2 authorize-security-group-ingress --region "$EKS_REGION" \
      --group-id "$CLUSTER_SG" --source-group "$SRC" --protocol all >/dev/null 2>&1 || true
    [ -n "$NODE_SG" ] && [ "$NODE_SG" != "None" ] && \
      aws ec2 authorize-security-group-ingress --region "$EKS_REGION" \
        --group-id "$NODE_SG" --source-group "$SRC" --protocol all >/dev/null 2>&1 || true
  done

  kubectl --context "$EKS_CLUSTER_NAME" wait --for=condition=ready pod -l app=ebs-csi-controller -n kube-system --timeout=300s 2>/dev/null || true

  echo "[EKS] Installing AWS Load Balancer Controller..."
  if helm --kube-context "$EKS_CLUSTER_NAME" list -n kube-system 2>/dev/null | grep -q aws-load-balancer-controller; then
    echo "[EKS] AWS LB Controller already installed"
  else
    VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[].SubnetId' --output text --region "$EKS_REGION")
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
      --query 'Subnets[].SubnetId' --output text --region "$EKS_REGION")
    for s in $PUBLIC_SUBNETS;  do aws ec2 create-tags --resources "$s" --tags Key=kubernetes.io/role/elb,Value=1          --region "$EKS_REGION" >/dev/null 2>&1 || true; done
    for s in $PRIVATE_SUBNETS; do aws ec2 create-tags --resources "$s" --tags Key=kubernetes.io/role/internal-elb,Value=1 --region "$EKS_REGION" >/dev/null 2>&1 || true; done

    POLICY_FILE="$TEMPLATE_DIR/.aws-lb-iam-policy.json"
    curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$AWS_LB_CONTROLLER_VERSION/docs/install/iam_policy.json" -o "$POLICY_FILE"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-$EKS_CLUSTER_NAME"
    if ! aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" >/dev/null 2>&1; then
      aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "file://$POLICY_FILE" >/dev/null
    fi
    sleep 5

    eksctl create iamserviceaccount \
      --cluster="$EKS_CLUSTER_NAME" \
      --namespace=kube-system \
      --name=aws-load-balancer-controller \
      --role-name "AmazonEKSLoadBalancerControllerRole-$EKS_CLUSTER_NAME" \
      --attach-policy-arn="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" \
      --approve --override-existing-serviceaccounts --region="$EKS_REGION" >/dev/null

    helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
    helm repo update eks >/dev/null
    helm --kube-context "$EKS_CLUSTER_NAME" install aws-load-balancer-controller eks/aws-load-balancer-controller \
      --version "$AWS_LB_CHART_VERSION" \
      -n kube-system \
      --set clusterName="$EKS_CLUSTER_NAME" \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region="$EKS_REGION" \
      --set vpcId="$VPC_ID" >/dev/null
    sleep 5
    kubectl --context "$EKS_CLUSTER_NAME" wait --for=condition=ready pod -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --timeout=300s 2>/dev/null || true
    rm -f "$POLICY_FILE"
  fi

  if ! kubectl --context "$EKS_CLUSTER_NAME" get storageclass documentdb-storage >/dev/null 2>&1; then
    kubectl --context "$EKS_CLUSTER_NAME" apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: documentdb-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  fsType: ext4
  encrypted: "true"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
  fi

  echo "[EKS] EKS member ready"
}

gke_deploy() {
  if [ -z "$GCP_PROJECT_ID" ] || [ -z "$GCP_USER" ]; then
    echo "[GKE] ERROR: INCLUDE_GKE=true but GCP_PROJECT_ID and/or GCP_USER not set" >&2
    exit 1
  fi
  echo "[GKE] Configuring project $GCP_PROJECT_ID..."
  gcloud config set account "$GCP_USER" >/dev/null
  gcloud config set project "$GCP_PROJECT_ID" >/dev/null
  if ! gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1; then
    gcloud projects create "$GCP_PROJECT_ID"
  fi
  gcloud services enable container.googleapis.com >/dev/null
  for r in container.admin compute.networkAdmin iam.serviceAccountUser; do
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" --member="user:$GCP_USER" --role="roles/$r" >/dev/null
  done

  if gcloud container clusters describe "$GKE_CLUSTER_NAME" --zone "$GCP_ZONE" --project "$GCP_PROJECT_ID" >/dev/null 2>&1; then
    gcloud container clusters delete "$GKE_CLUSTER_NAME" --zone "$GCP_ZONE" --project "$GCP_PROJECT_ID" --quiet
  fi
  gcloud container clusters create "$GKE_CLUSTER_NAME" \
    --cluster-version "$KUBERNETES_VERSION" \
    --zone "$GCP_ZONE" --num-nodes 2 --machine-type "e2-standard-4" \
    --enable-ip-access --project "$GCP_PROJECT_ID"

  kubectl config delete-context "$GKE_CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$GKE_CLUSTER_NAME" >/dev/null 2>&1 || true
  kubectl config delete-user    "$GKE_CLUSTER_NAME" >/dev/null 2>&1 || true
  gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --location="$GCP_ZONE"
  fullName="gke_${GCP_PROJECT_ID}_${GCP_ZONE}_${GKE_CLUSTER_NAME}"
  if [ -f "$HOME/.kube/config" ]; then
    sed -i "s|$fullName|$GKE_CLUSTER_NAME|g" "$HOME/.kube/config" || true
  fi
  echo "[GKE] GKE member ready"
}

check_prerequisites

echo ""
echo "=== Provisioning member clusters ==="
# Credential writers share kubeconfig; serialize them to avoid lost contexts.
aks_fleet_deploy

if [ "$INCLUDE_GKE" = "true" ]; then
  gke_deploy
fi

if [ "$INCLUDE_EKS" = true ]; then eks_deploy; fi

echo ""
echo "Fleet infrastructure deployed. Members: ${MEMBER_CLUSTER_NAMES[*]}"

temp_dir=$(mktemp -d)
echo ""
echo "=== Joining members to Fleet (temp: $temp_dir) ==="
pushd "$temp_dir" >/dev/null
git clone --quiet https://github.com/kubefleet-dev/kubefleet.git
git clone --quiet https://github.com/Azure/fleet-networking.git
git -C fleet-networking checkout --quiet 71e5f8671d45e8f78f607f5c350ea2a568335c70

# Windows checkouts materialise git symlinks as text files containing the link
# target. Restore them so helm can parse the chart. (See docs/upstream-issues.md)
restore_chart_symlinks() {
  local chartroot="$1"
  find "$chartroot" -type f \( -name '*.yaml' -o -name '*.yml' \) -size -300c -print0 \
    | while IFS= read -r -d '' f; do
        local content target resolved
        content=$(tr -d '[:space:]' <"$f")
        if [[ "$content" =~ ^\.\..*\.yaml$|^\.\..*\.yml$ ]]; then
          target=$(cat "$f" | tr -d '\r\n')
          resolved="$(dirname "$f")/$target"
          [ -f "$resolved" ] && cp "$resolved" "$f"
        fi
      done
}

pushd "$temp_dir/kubefleet" >/dev/null
git checkout --quiet d3f42486fa78874e33ba8e6e5e34636767f77b8f
restore_chart_symlinks charts/
chmod +x hack/membership/joinMC.sh
NON_AKS_MEMBERS=()
for c in "${MEMBER_CLUSTER_NAMES[@]}"; do
  [ "$c" = "$AKS_CLUSTER_NAME" ] && continue
  [ "$INCLUDE_AKS_REPLICA" = true ] && [ "$c" = "$AKS_REPLICA_NAME" ] && continue
  NON_AKS_MEMBERS+=("$c")
done
if [ "${#NON_AKS_MEMBERS[@]}" -gt 0 ]; then
  hack/membership/joinMC.sh "v0.16.9" "$HUB_CONTEXT" "${NON_AKS_MEMBERS[@]}"
fi
popd >/dev/null

for c in "${NON_AKS_MEMBERS[@]}"; do
  echo "Waiting for $c to join Fleet..."
  kubectl --context "$HUB_CONTEXT" wait --for=jsonpath='{.status.resourceUsage.observationTime}' "membercluster/$c" --timeout=300s
done

pushd "$temp_dir/fleet-networking" >/dev/null
restore_chart_symlinks charts/
chmod +x hack/membership/joinMC.sh
if [ "${#NON_AKS_MEMBERS[@]}" -gt 0 ]; then
  hack/membership/joinMC.sh "v0.16.5" "v0.3.24" "$HUB_CONTEXT" "${NON_AKS_MEMBERS[@]}"
fi
# Apply networking CRDs explicitly (joinMC.sh does this with `apply -f config/crd/*`
# which fails because that's a directory with subdirs)
for c in "${NON_AKS_MEMBERS[@]}"; do
  for crd in config/crd/bases/*.yaml; do
    kubectl --context "$c" apply -f "$crd" >/dev/null
  done
  kubectl --context "$c" -n fleet-system rollout restart deploy member-net-controller-manager >/dev/null
done
popd >/dev/null
popd >/dev/null

echo ""
echo "=== Installing Istio multi-cluster mesh ==="
istio_tmp=$(mktemp -d)
# Use the CLI and samples from the same release, regardless of PATH.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      pushd "$istio_tmp" >/dev/null
      curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-win.zip" -o istio.zip
      unzip -q istio.zip
      popd >/dev/null
      ;;
    *)
      curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" |
        tar -xz -C "$istio_tmp"
      ;;
esac
export PATH="$istio_tmp/istio-$ISTIO_VERSION/bin:$PATH"
git clone --quiet --depth 1 --branch "$ISTIO_VERSION" https://github.com/istio/istio.git "$istio_tmp/istio"
ISTIO_DIR="$istio_tmp/istio"
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
# Fleet's hub must recognize the PeerAuthentication placed with the database.
kubectl --context "$HUB_CONTEXT" apply --server-side --field-manager=documentdb-demo \
  -f "$ISTIO_DIR/manifests/charts/base/files/crd-all.gen.yaml"

mkdir -p "$TEMPLATE_DIR/certs"
pushd "$TEMPLATE_DIR/certs" >/dev/null
if [ ! -f root-cert.pem ]; then
  for cluster in "${MEMBER_CLUSTER_NAMES[@]}"; do
    if kubectl --context "$cluster" -n istio-system get secret cacerts >/dev/null 2>&1; then
      echo "ERROR: mesh CA exists on $cluster but local CA is missing. Restore certs/; do not rotate a live mesh implicitly." >&2
      exit 1
    fi
  done
  make -f "$ISTIO_DIR/tools/certs/Makefile.selfsigned.mk" root-ca
fi

for cluster in "${MEMBER_CLUSTER_NAMES[@]}"; do
  echo "  Istio -> $cluster (network=$cluster)"
  make -f "$ISTIO_DIR/tools/certs/Makefile.selfsigned.mk" "${cluster}-cacerts"
  kubectl --context "$cluster" create namespace istio-system --dry-run=client -o yaml | kubectl --context "$cluster" apply -f -
  kubectl --context "$cluster" wait --for=jsonpath='{.status.phase}'=Active namespace/istio-system --timeout=60s
  kubectl --context "$cluster" create secret generic cacerts -n istio-system \
    --from-file="${cluster}/ca-cert.pem" \
    --from-file="${cluster}/ca-key.pem" \
    --from-file="${cluster}/root-cert.pem" \
    --from-file="${cluster}/cert-chain.pem" --dry-run=client -o yaml | kubectl --context "$cluster" apply -f -
  kubectl --context "$cluster" label namespace istio-system "topology.istio.io/network=$cluster" --overwrite

  helm --kube-context "$cluster" upgrade --install istio-base istio/base --version "$ISTIO_VERSION" -n istio-system --wait
  helm --kube-context "$cluster" upgrade --install istiod istio/istiod --version "$ISTIO_VERSION" -n istio-system \
    --set global.meshID=mesh1 --set-string global.multiCluster.clusterName="$cluster" \
    --set-string global.network="$cluster" --wait
  helm --kube-context "$cluster" upgrade --install istio-eastwestgateway istio/gateway --version "$ISTIO_VERSION" -n istio-system \
    --set-string networkGateway="$cluster" --set labels.istio=eastwestgateway \
    --set autoscaling.minReplicas=2 --wait

  kubectl --context "$cluster" apply -n istio-system -f \
    "$ISTIO_DIR/samples/multicluster/expose-services.yaml"

done

for cluster in "${MEMBER_CLUSTER_NAMES[@]}"; do
  remoteSecretFile="$istio_tmp/${cluster}-remote-secret.yaml"
  istioctl create-remote-secret --context="$cluster" --name="$cluster" > "$remoteSecretFile"
  for other in "${MEMBER_CLUSTER_NAMES[@]}"; do
    [ "$cluster" = "$other" ] && continue
    kubectl --context="$other" apply -f "$remoteSecretFile"
  done
done
popd >/dev/null

if [ "$INCLUDE_EKS" = true ]; then
echo "  Annotating EKS east-west gateway as internet-facing NLB..."
kubectl --context "$EKS_CLUSTER_NAME" -n istio-system annotate service istio-eastwestgateway --overwrite \
  service.beta.kubernetes.io/aws-load-balancer-type="nlb" \
  service.beta.kubernetes.io/aws-load-balancer-scheme="internet-facing" \
  service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled="true" \
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type="ip"
fi

echo ""
echo "=== Installing published DocumentDB operator on hub and members ==="
# Do not propagate webhook certificates or Helm-managed operators through Fleet.
if kubectl --context "$HUB_CONTEXT" get clusterresourceplacement documentdb-base -o name --ignore-not-found | grep -q .; then
  echo "ERROR: legacy documentdb-base placement exists. Migrate the old stack before installing independent GA charts (see SETUP.md)." >&2
  exit 1
fi
chart_args=()
if [ -n "$VALUES_FILE" ]; then chart_args+=(--values "$VALUES_FILE"); fi
for cluster in "$HUB_CONTEXT" "${MEMBER_CLUSTER_NAMES[@]}"; do
  if [ "$cluster" != "$HUB_CONTEXT" ]; then
    kubectl --context "$cluster" create namespace documentdb-operator --dry-run=client -o yaml | kubectl --context "$cluster" apply -f -
    kubectl --context "$cluster" label namespace documentdb-operator istio-injection=enabled --overwrite
  fi
  install_documentdb_operator "$cluster" "${chart_args[@]}"
done

echo ""
echo "Verifying operator installations on members..."
for cluster in "${MEMBER_CLUSTER_NAMES[@]}"; do
  READY=$(kubectl --context "$cluster" get deploy documentdb-operator -n documentdb-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl --context "$cluster" get deploy documentdb-operator -n documentdb-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  echo "  $cluster: ${READY:-0}/${DESIRED:-0} replicas ready"
done

echo ""
echo "============================================================"
echo "Multi-cloud Fleet + Istio + DocumentDB operator deployed"
echo ""
echo "Members: ${MEMBER_CLUSTER_NAMES[*]}"
echo "Hub context: $HUB_CONTEXT"
echo ""
echo "Next: bash $TEMPLATE_DIR/deploy-documentdb.sh"
echo "============================================================"
