#!/usr/bin/env bash
# Deploy Azure OpenAI account + text-embedding-3-small deployment, then write
# .env at the repo root with the endpoint, key, and deployment name.
#
# Usage:
#   bash infra/azure/deploy-openai.sh
#
# Env overrides:
#   RESOURCE_GROUP   default: docdb-demo-aoai-rg
#   LOCATION         default: swedencentral
#   ACCOUNT_NAME     default: docdb-demo-aoai
#   ENV_FILE         default: <repo-root>/.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-demo-aoai-rg}"
LOCATION="${LOCATION:-swedencentral}"
ACCOUNT_NAME="${ACCOUNT_NAME:-docdb-demo-aoai}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

echo "==> Subscription:"
az account show --query "{name:name, id:id}" -o table

echo "==> Ensuring resource group $RESOURCE_GROUP in $LOCATION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> Deploying Azure OpenAI account + embedding deployment"
DEPLOY_NAME="aoai-$(date +%Y%m%d-%H%M%S)"
az deployment group create \
  --name "$DEPLOY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/openai.bicep" \
  --parameters "$SCRIPT_DIR/openai.bicepparam" \
  --parameters accountName="$ACCOUNT_NAME" location="$LOCATION" \
  -o none

ENDPOINT=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" --query 'properties.outputs.endpoint.value' -o tsv)
DEPLOYMENT_NAME=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" --query 'properties.outputs.embeddingDeploymentName.value' -o tsv)
RESOLVED_ACCOUNT=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" --query 'properties.outputs.accountName.value' -o tsv)

echo "==> Fetching API key for $RESOLVED_ACCOUNT"
KEY=$(az cognitiveservices account keys list \
  --name "$RESOLVED_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'key1' -o tsv)

if [[ -z "${KEY:-}" || -z "${ENDPOINT:-}" ]]; then
  echo "ERROR: failed to read endpoint or key from deployment outputs" >&2
  exit 1
fi

echo "==> Writing $ENV_FILE"
# Idempotent upsert: strip any existing AZURE_OPENAI_* lines, then append fresh values
TMP_FILE="$(mktemp)"
if [[ -f "$ENV_FILE" ]]; then
  grep -Ev '^AZURE_OPENAI_(ENDPOINT|API_KEY|EMBEDDING_DEPLOYMENT|EMBEDDING_MODEL|API_VERSION)=' "$ENV_FILE" > "$TMP_FILE" || true
else
  : > "$TMP_FILE"
fi

cat >> "$TMP_FILE" <<EOF
# --- Azure OpenAI (deployed by infra/azure/deploy-openai.sh) ---
AZURE_OPENAI_ENDPOINT=$ENDPOINT
AZURE_OPENAI_API_KEY=$KEY
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=$DEPLOYMENT_NAME
AZURE_OPENAI_EMBEDDING_MODEL=text-embedding-3-small
AZURE_OPENAI_API_VERSION=2024-10-21
EOF

mv "$TMP_FILE" "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true

echo
echo "==> Done."
echo "    Resource group:      $RESOURCE_GROUP"
echo "    Account:             $RESOLVED_ACCOUNT"
echo "    Region:              $LOCATION"
echo "    Endpoint:            $ENDPOINT"
echo "    Deployment name:     $DEPLOYMENT_NAME"
echo "    .env updated:        $ENV_FILE  (key not echoed)"
echo
echo "NOTE: .env contains a secret. It is gitignored — do not commit it."
