#!/bin/bash
# Persistent port-forward to the DocumentDB AKS/EKS gateway.
# Auto-restarts if the connection drops (e.g., laptop sleep, idle timeout, pod restart).
#
# Why this exists: cloud LoadBalancers in front of DocumentDB sometimes drop the
# TLS handshake from external clients (LB session affinity / cert SNI mismatch).
# A kubectl port-forward bypasses the LB and gives a clean, reliable mongo URI
# for demos and the VS Code DocumentDB extension.
#
# Usage:
#   ./portforward.sh                # AKS, default ports
#   CONTEXT=eks-demo ./portforward.sh
#   LOCAL_PORT=12260 ./portforward.sh
#
set -uo pipefail

CONTEXT="${CONTEXT:-aks-demo}"
NAMESPACE="${NAMESPACE:-documentdb-ns}"
SERVICE="${SERVICE:-documentdb-service-docdb-demo}"
LOCAL_PORT="${LOCAL_PORT:-11260}"
REMOTE_PORT="${REMOTE_PORT:-10260}"
SECRET="${SECRET:-docdb-demo-credentials}"

echo "============================================"
echo "  DocumentDB persistent port-forward"
echo "============================================"
echo "  Context:   $CONTEXT"
echo "  Namespace: $NAMESPACE"
echo "  Service:   $SERVICE"
echo "  Local:     localhost:$LOCAL_PORT  ->  $REMOTE_PORT"
echo ""

USER=$(kubectl --context "$CONTEXT" get secret -n "$NAMESPACE" "$SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
PASS=$(kubectl --context "$CONTEXT" get secret -n "$NAMESPACE" "$SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [[ -n "$USER" && -n "$PASS" ]]; then
  URI="mongodb://${USER}:${PASS}@localhost:${LOCAL_PORT}/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256"
  echo "Connection URI (paste into VS Code DocumentDB extension):"
  echo ""
  echo "  $URI"
  echo ""
fi

echo "Press Ctrl+C to stop. Auto-restarts on drop."
echo "--------------------------------------------"

trap 'echo ""; echo "Stopping port-forward."; exit 0' INT TERM

while true; do
  kubectl --context "$CONTEXT" port-forward -n "$NAMESPACE" "svc/$SERVICE" "${LOCAL_PORT}:${REMOTE_PORT}" || true
  echo ""
  echo "[$(date '+%H:%M:%S')] port-forward exited; restarting in 2s..."
  sleep 2
done
