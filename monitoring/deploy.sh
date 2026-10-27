#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../infra/multi-cloud/config.sh"
source "$SCRIPT_DIR/../infra/versions.sh"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
for context in "${MEMBER_CLUSTER_NAMES[@]}"; do
  helm --kube-context "$context" upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$PROMETHEUS_STACK_VERSION" --namespace monitoring --create-namespace \
    --values "$SCRIPT_DIR/helm/values-kube-prometheus.yaml" \
    --set-string "prometheus.prometheusSpec.externalLabels.member=$context" --wait --timeout=10m
  kubectl --context "$context" -n monitoring create configmap documentdb-failover-dashboard \
    --from-file="$SCRIPT_DIR/dashboards/documentdb-failover.json" --dry-run=client -o yaml |
    kubectl --context "$context" apply -f -
  kubectl --context "$context" -n monitoring label configmap documentdb-failover-dashboard grafana_dashboard=1 --overwrite
  kubectl --context "$context" apply -f "$SCRIPT_DIR/manifests/podmonitor-cnpg.yaml" \
    -f "$SCRIPT_DIR/manifests/peerauth-cnpg-metrics.yaml"
done
