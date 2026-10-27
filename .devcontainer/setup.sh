#!/bin/bash
# Post-create setup for Codespaces / devcontainer
set -e

echo "=== Setting up DocumentDB demo environment ==="

# Install Python dependencies
pip install pymongo python-dotenv openai langchain fastapi uvicorn

# Pull and start DocumentDB local
echo "Starting DocumentDB local..."
LOCAL_IMAGE="ghcr.io/documentdb/documentdb/documentdb-local:pg18-1.0.0@sha256:03aef53ed72cd3007236f8ce1b4ef7a0c958dbbce1519074b85d8a3e10be89a5"
docker pull "$LOCAL_IMAGE"
docker run -dt -p 10260:10260 --name docdb \
  "$LOCAL_IMAGE" \
  --username demo --password test

# Wait for DocumentDB to be ready
echo "Waiting for DocumentDB..."
for i in {1..20}; do
  if docker exec docdb mongosh "mongodb://demo:test@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true" --eval "db.runCommand({ping:1})" 2>/dev/null; then
    echo "✅ DocumentDB is ready"
    break
  fi
  sleep 3
done

echo ""
echo "=== Setup complete ==="
echo "DocumentDB: mongodb://demo:test@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
