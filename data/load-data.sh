#!/bin/bash
# Load demo data into DocumentDB
# Works against local, AKS, or EKS — just set MONGODB_URI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_FILE="${DATA_FILE:-${SCRIPT_DIR}/booking-agents_vectors.json}"
DB_NAME="${DB_NAME:-demodb}"
COLLECTION_NAME="${COLLECTION_NAME:-stays}"

# Default to local connection
MONGODB_URI="${MONGODB_URI:-mongodb://demo:test@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true}"

echo "=== Loading demo data ==="
echo "Target: $MONGODB_URI"
echo "Database: $DB_NAME"
echo "Collection: $COLLECTION_NAME"
echo "Data file: $DATA_FILE"

if [ ! -f "$DATA_FILE" ]; then
  echo "❌ Data file not found: $DATA_FILE"
  exit 1
fi

START_TIME=$(date +%s)

# Import using mongoimport (fast, handles large files)
if command -v mongoimport &>/dev/null; then
  echo "Using mongoimport..."
  mongoimport \
    --uri="$MONGODB_URI" \
    --db="$DB_NAME" \
    --collection="$COLLECTION_NAME" \
    --file="$DATA_FILE" \
    --jsonArray \
    --drop
else
  # Fallback to mongosh
  echo "mongoimport not found, using mongosh..."
  mongosh "$MONGODB_URI" --eval "
    use('$DB_NAME');
    db['$COLLECTION_NAME'].drop();
    const fs = require('fs');
    const data = JSON.parse(fs.readFileSync('$DATA_FILE', 'utf8'));
    const result = db['$COLLECTION_NAME'].insertMany(data);
    print('Inserted: ' + result.insertedIds.length + ' documents');
  " --quiet
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Create vector search index
echo ""
echo "=== Creating vector search index ==="
mongosh "$MONGODB_URI" --eval "
  use('$DB_NAME');
  db.runCommand({
    createIndexes: '$COLLECTION_NAME',
    indexes: [{
      key: { 'descriptionVector': 'cosmosSearch' },
      name: 'vectorSearchIndex',
      cosmosSearchOptions: {
        kind: 'vector-hnsw',
        similarity: 'COS',
        dimensions: 1536
      }
    }]
  });
  print('Vector index created');
  
  // Also create useful query indexes for filter/sort demos
  db['$COLLECTION_NAME'].createIndex({ property_type: 1, price: 1 });
  db['$COLLECTION_NAME'].createIndex({ price: 1 });
  db['$COLLECTION_NAME'].createIndex({ bedrooms: 1, beds: 1 });
  db['$COLLECTION_NAME'].createIndex({ tags: 1 });
  print('Query indexes created');
  
  const count = db['$COLLECTION_NAME'].countDocuments();
  print('Total documents: ' + count);
" --quiet

echo ""
echo "✅ Data loaded in ${ELAPSED}s"
echo "   Database: $DB_NAME"
echo "   Collection: $COLLECTION_NAME"
echo "   Vector index: vectorSearchIndex (HNSW, cosine, 1536 dim)"
