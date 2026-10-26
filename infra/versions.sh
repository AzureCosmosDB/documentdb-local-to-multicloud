#!/usr/bin/env bash
# Published releases verified 2026-10-26. See SETUP.md before upgrading existing data.
OPERATOR_VERSION="${OPERATOR_VERSION:-1.0.0}"
DOCUMENTDB_VERSION="${DOCUMENTDB_VERSION:-1.0.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
# 1.31.3 has a GitHub release but no published gateway chart in the chart registry.
ISTIO_VERSION="${ISTIO_VERSION:-1.30.7}"
PROMETHEUS_STACK_VERSION="${PROMETHEUS_STACK_VERSION:-92.14.0}"
AWS_LB_CHART_VERSION="${AWS_LB_CHART_VERSION:-3.6.2}"
AWS_LB_CONTROLLER_VERSION="${AWS_LB_CONTROLLER_VERSION:-v3.6.2}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"
VERSIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_documentdb_operator() {
  local context="$1" installed
  shift
  installed=$(helm --kube-context "$context" list -n documentdb-operator -o json |
    jq -r '.[] | select(.name == "documentdb-operator") | .chart')
  if [ -n "$installed" ] && [ "$installed" != "documentdb-operator-$OPERATOR_VERSION" ] &&
     [ "${ALLOW_OPERATOR_UPGRADE:-false}" != "true" ]; then
    echo "ERROR: $context has $installed. Follow the upstream migration guide first; set ALLOW_OPERATOR_UPGRADE=true only after preparing existing clusters." >&2
    return 1
  fi
  helm --kube-context "$context" upgrade --install cert-manager \
    oci://quay.io/jetstack/charts/cert-manager --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout=5m
  helm --kube-context "$context" upgrade --install documentdb-operator \
    oci://ghcr.io/documentdb/documentdb-operator --version "$OPERATOR_VERSION" \
    --namespace documentdb-operator --create-namespace \
    --set-string documentDbVersion="$DOCUMENTDB_VERSION" \
    --set-file "cloudnative-pg.monitoringQueriesConfigMap.queries=$VERSIONS_DIR/../monitoring/queries.yaml" \
    --wait --timeout=10m "$@"
}
