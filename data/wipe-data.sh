#!/bin/bash
# Wipe demo data and/or indexes from DocumentDB
# Works against local, AKS, or EKS — just set MONGODB_URI
#
# Usage:
#   ./wipe-data.sh              # Wipe everything (drop database)
#   ./wipe-data.sh --indexes    # Drop indexes only (keep data for Index Advisor demo)
#   ./wipe-data.sh --data       # Drop data only (keep indexes)
set -euo pipefail

DB_NAME="${DB_NAME:-demodb}"
COLLECTION_NAME="${COLLECTION_NAME:-stays}"
MONGODB_URI="${MONGODB_URI:-mongodb://demo:test@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true}"

MODE="${1:---all}"

echo "=== Wiping demo environment ==="
echo "Target: $MONGODB_URI"
echo "Database: $DB_NAME"
echo "Mode: $MODE"

case $MODE in
  --indexes)
    echo ""
    echo "Dropping all non-_id indexes (keeping data)..."
    mongosh "$MONGODB_URI" --eval "
      use('$DB_NAME');
      const indexes = db['$COLLECTION_NAME'].getIndexes();
      let dropped = 0;
      indexes.forEach(idx => {
        if (idx.name !== '_id_') {
          db['$COLLECTION_NAME'].dropIndex(idx.name);
          print('  Dropped: ' + idx.name);
          dropped++;
        }
      });
      print('Dropped ' + dropped + ' indexes. Data preserved.');
      print('Documents: ' + db['$COLLECTION_NAME'].countDocuments());
    " --quiet
    echo "✅ Indexes wiped. Data preserved. Ready for Index Advisor demo."
    ;;
  --data)
    echo ""
    echo "Dropping collection data (keeping database)..."
    mongosh "$MONGODB_URI" --eval "
      use('$DB_NAME');
      db['$COLLECTION_NAME'].deleteMany({});
      print('All documents deleted. Indexes preserved.');
    " --quiet
    echo "✅ Data wiped. Indexes preserved. Ready for data import demo."
    ;;
  --all|*)
    echo ""
    echo "Dropping entire database..."
    mongosh "$MONGODB_URI" --eval "
      use('$DB_NAME');
      db.dropDatabase();
      print('Database dropped: $DB_NAME');
    " --quiet
    echo "✅ Database dropped. Clean slate for full demo."
    ;;
esac
