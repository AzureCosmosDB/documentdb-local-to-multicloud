# Upstream Issues Discovered

Captured during multi-cloud DocumentDB demo build (Techorama 2026 prep).
File these as issues / PRs against the relevant upstream repos when convenient.

---

## 1. kubefleet — Symlinks in helm chart break Windows checkouts

**Repo:** https://github.com/kubefleet-dev/kubefleet
**Pinned commit tested:** `d3f42486fa78874e33ba8e6e5e34636767f77b8f`

**Symptom:**
```
Error: YAML parse error on member-agent/templates/crds/appliedworks.yaml:
  error unmarshaling JSON: while decoding JSON:
  json: cannot unmarshal string into Go value of type releaseutil.SimpleHead
```

**Root cause:** `charts/{member-agent,hub-agent}/crdbases/*.yaml` and several files
under `charts/hub-agent/templates/crds/*.yaml` are git symlinks pointing to
`../../../../config/crd/bases/*.yaml`. On Windows checkouts (no symlink
support without `core.symlinks=true` + admin), git materialises them as
plain text files containing the link target string. Helm then tries to parse
that string as YAML and produces the misleading `SimpleHead` error.

Same pattern affects `Azure/fleet-networking` (`charts/{mcs-controller-manager,member-net-controller-manager}/...`).

**Reproduction:** Clone on Windows (no symlink support), run
`helm install member-agent ./charts/member-agent --set ...`. Fails 100%.

**Local fix used:** Walk the chart, detect text files <300 bytes whose
content matches `^\.\..+\.yaml\s*$`, copy the resolved target over the link.
See `infra/multi-cloud/deploy.sh` (proposed patch below).

**Suggested upstream fix (any one of these):**
1. Replace symlinks with a `helm template` partial that reads from a single
   source-of-truth path inside the chart.
2. Pre-render the chart in CI and ship the rendered `crdbases/` files in releases.
3. Convert symlinks to hard copies via a `make sync-crds` Makefile target
   referenced in CONTRIBUTING + a CI guard.
4. Document the requirement and add a `bin/restore-symlinks-windows.sh` to repo.

**Suggested PR:**
- Title: `fix(charts): replace CRD symlinks with copied files for Windows compat`
- File: `Makefile` adds `sync-crds` target; CI step that fails if symlinks reappear.

---

## 2. DocumentDB operator — K8s 1.35 hard requirement is a sharp wall

**Repo:** https://github.com/documentdb/documentdb-kubernetes-operator
**Tag:** `v0.2.0` (operator image `ghcr.io/documentdb/documentdb-kubernetes-operator/operator:0.2.0`)

**Symptom:** Operator immediately exits at startup on K8s 1.34:
```
ERROR  setup  unable to create controller  {"controller": "DocumentDB",
  "error": "kubernetes version 1.34 is not supported: the DocumentDB operator
  requires Kubernetes 1.35+ for ImageVolume support (GA in K8s 1.35).
  Please upgrade your cluster"}
```

**Issues to file:**

a) **README + chart `values.yaml` should declare the K8s version requirement
   prominently.** Currently no warning before `helm install` succeeds and
   pods crashloop minutes later.

b) **Helm chart should add `kubeVersion: ">=1.35.0-0"` to `Chart.yaml`** so
   `helm install` fails fast with a clear error instead of letting the pod
   crashloop.

c) **Consider a feature flag** to fall back to a `hostPath` / `emptyDir`
   pattern for the gateway sidecar TLS material on K8s <1.35, even if the
   operator requires K8s 1.35 for production. This unblocks demo / CI / dev
   workflows where the cluster lifecycle is slower than the operator's.

d) **Document AKS / EKS minimum versions explicitly** in install docs since
   AKS 1.35 only became GA recently and EKS 1.35 just hit STANDARD_SUPPORT.

---

## 3. Multi-cloud deploy.sh — Istio version pin

**Repo:** https://github.com/documentdb/documentdb-kubernetes-operator
**Path:** `documentdb-playground/multi-cloud-deployment/deploy.sh` (line 407)

**Symptom:** Uses unpinned Istio (was 1.24.0 default). Istio 1.24 dropped
the `IstioOperator` API; the script's `gen-eastwest-gateway.sh` step fails:
```
Error: generate config: helm render: load chart: component does not exist
```

**Fix:** Pin `ISTIO_VERSION="1.23.4"` (last release with `IstioOperator`),
or migrate the script to the new `IstioRevisionTag` / Sail Operator model.

**Bonus:** The Linux-only `curl https://istio.io/downloadIstio | sh` doesn't
work on Windows / Git Bash. Use direct release-asset download
(`istio-${VER}-win.zip`) when `OSTYPE` is mingw/cygwin.

---

## 4. Multi-cloud deploy.sh — EKS cluster security group missing self-ingress

**Repo:** Same as above (`infra/aws/deploy.sh` in this repo, plus upstream
playground)

**Symptom:** Right after `eksctl create cluster`, kube-system pods
crashloop with:
```
dial tcp 10.x.x.x:10250: i/o timeout
```
CoreDNS readiness probe returns 503; DNS resolution fails cluster-wide;
ebs-csi controller and metrics-server cascade-fail.

**Root cause:** AWS VPC CNI assigns pod ENIs that use *only* the cluster
security group (not the node SG). Without **self-ingress on the cluster SG**,
pod-to-pod traffic is blocked even though node-to-control-plane works.

**Fix:** After cluster create, add four SG rules:
```bash
CLUSTER_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$EKS_REGION" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
NODE_SG=$(aws ec2 describe-security-groups --region "$EKS_REGION" \
  --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=$EKS_CLUSTER_NAME" \
            "Name=group-name,Values=*nodegroup*" --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$CLUSTER_SG" --source-group "$CLUSTER_SG" --protocol all --region "$EKS_REGION"
aws ec2 authorize-security-group-ingress --group-id "$CLUSTER_SG" --source-group "$NODE_SG"    --protocol all --region "$EKS_REGION"
aws ec2 authorize-security-group-ingress --group-id "$NODE_SG"    --source-group "$CLUSTER_SG" --protocol all --region "$EKS_REGION"
aws ec2 authorize-security-group-ingress --group-id "$NODE_SG"    --source-group "$NODE_SG"    --protocol all --region "$EKS_REGION"
```

Already patched locally in `infra/aws/deploy.sh`.

---

## 5. Multi-cloud deploy.sh — AWS LB controller is installed but ServiceAccount IRSA is not

**Symptom:** `aws-load-balancer-controller` deployment 0/2 ready with:
```
error looking up service account kube-system/aws-load-balancer-controller:
  serviceaccount "aws-load-balancer-controller" not found
```
Then the orphaned `aws-load-balancer-webhook` mutating webhook *blocks every
service create call* in the cluster (e.g., `cert-manager-webhook` install
fails with "no endpoints available for service aws-load-balancer-webhook-service").

**Fix options:**
- Don't install the AWS LB controller at all if not used (the demo uses Istio
  east-west NLBs; CLBs work fine).
- Or, complete the IRSA setup: create the IAM OIDC provider, IAM policy,
  IAM role, and `--override-existing-serviceaccounts` in eksctl.

Already patched locally by removing the broken deployment + webhook
configurations.

---

## 6. Istio multicluster — east-west gateway PDB blocks node drains

**Repo:** https://github.com/istio/istio
**File:** `samples/multicluster/gen-eastwest-gateway.sh` (and the IstioOperator
manifest it emits)

**Symptom:** Cluster upgrade (AKS, EKS, anything that drains nodes) fails with:
```
Cannot evict pod as it would violate the pod's disruption budget.
PDB debug info: istio-system/istio-eastwestgateway-... blocked by pdb
istio-eastwestgateway (MinAvailable: 1) (CurrentHealthy: 1) (DesiredHealthy: 1)
```

**Root cause:** The sample installs a single-replica deployment and a PDB with
`minAvailable: 1`. Together those make the gateway un-drainable — the upgrade
hangs forever and eventually times out / fails the cluster.

**Fix:** Default the sample to 2 replicas, or (better) emit a PDB with
`maxUnavailable: 1` instead of `minAvailable: 1`. Either change makes the
gateway both HA and drainable.

**Workaround in our fork:** `infra/multi-cloud/deploy.sh` scales
`istio-eastwestgateway` to `replicas=2` immediately after install.

---

## Priority ranking for upstream PRs

1. **kubefleet symlinks** — affects every Windows user. Fixable in a few
   lines. Highest impact-per-effort.
2. **DocumentDB operator chart `kubeVersion`** — one-line fix that turns a
   crashloop mystery into a clear `helm install` error.
3. **DocumentDB operator README** — document K8s 1.35 requirement.
4. **Multi-cloud deploy.sh Istio pin** — one-line fix; prevents future
   regression when Istio drops more APIs.
5. **Multi-cloud deploy.sh EKS SG + AWS LB controller** — already in our
   fork. Worth upstreaming as a coherent EKS prep block.
6. **Istio east-west gateway PDB** — would silently break upgrade flows for
   anyone running multi-cluster Istio in production. Two-line fix.
