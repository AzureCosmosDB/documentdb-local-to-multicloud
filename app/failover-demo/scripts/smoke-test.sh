#!/usr/bin/env bash
# Smoke test: points both cluster slots at the local Docker DocumentDB
# (docker compose up at the repo root) and runs the writer for ~10s.
# Exits 0 if at least 5 docs land in the local DB.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

URI="${SMOKE_URI:-mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true}"
TMP_CFG="$ROOT/.smoke-clusters.json"

cat > "$TMP_CFG" <<JSON
{
  "aks": {
    "name": "AKS (smoke)",
    "region": "local",
    "uri": "$URI",
    "kubeContext": "noop",
    "namespace": "documentdb-preview-ns",
    "documentdbResource": "documentdb-preview"
  },
  "eks": {
    "name": "EKS (smoke)",
    "region": "local",
    "uri": "$URI",
    "kubeContext": "noop",
    "namespace": "documentdb-preview-ns",
    "documentdbResource": "documentdb-preview"
  },
  "hubContext": "noop",
  "initialPrimary": "aks"
}
JSON

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_CFG"
}
trap cleanup EXIT

echo "[smoke] building server…"
(cd server && npm run build >/dev/null)

echo "[smoke] starting server with smoke config…"
CLUSTERS_CONFIG="$TMP_CFG" PORT=4099 LOG_LEVEL=warn node server/dist/index.js &
SERVER_PID=$!

# Wait for /healthz
for i in $(seq 1 30); do
  if curl -fsS http://localhost:4099/healthz >/dev/null 2>&1; then break; fi
  sleep 0.5
done

echo "[smoke] running for 10s with auto-insert at 5 Hz…"
curl -fsS -X POST http://localhost:4099/api/auto-insert \
  -H 'content-type: application/json' \
  -d '{"enabled":true,"rateHz":5}' >/dev/null
sleep 10

STATE=$(curl -fsS http://localhost:4099/api/state)
echo "[smoke] state snapshot:"
echo "$STATE" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const s=JSON.parse(d);console.log(JSON.stringify({primary:s.primary,aks:{role:s.clusters.aks.role,docCount:s.clusters.aks.docCount,reachable:s.clusters.aks.reachable},eks:{role:s.clusters.eks.role,docCount:s.clusters.eks.docCount,reachable:s.clusters.eks.reachable}},null,2))})"

COUNT=$(echo "$STATE" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const s=JSON.parse(d);console.log(s.clusters.aks.docCount||0)})")

if [[ "$COUNT" -ge 5 ]]; then
  echo "[smoke] PASS — $COUNT docs in failover_demo_events"
  exit 0
else
  echo "[smoke] FAIL — only $COUNT docs"
  exit 1
fi
