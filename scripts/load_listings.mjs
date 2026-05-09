// Load bookingsdb.listings from data/listings_vectors.json + create demo indexes.
//
// Usage:
//   $env:MONGODB_URI = "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
//   node scripts/load_listings.mjs
//
// Or for cloud clusters (port-forwarded gateway):
//   $env:MONGODB_URI = "mongodb://docdb:<PWD>@127.0.0.1:57017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
//   node scripts/load_listings.mjs
//
// Env vars:
//   MONGODB_URI           full connection string (preferred)
//   DDB_DATABASE          default "bookingsdb"
//   DDB_COLLECTION        default "listings"
//   DATA_FILE             default ../data/listings_vectors.json (resolved from script dir)
//
// Legacy positional args still work for the AKS/EKS bootstrapping case:
//   node scripts/load_listings.mjs <port> <password>   (uses docdb user, 127.0.0.1)
import { MongoClient } from "mongodb";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const dataFile = process.env.DATA_FILE || resolve(__dir, "..", "data", "listings_vectors.json");
const dbName = process.env.DDB_DATABASE || "bookingsdb";
const colName = process.env.DDB_COLLECTION || "listings";

let uri = process.env.MONGODB_URI;
if (!uri) {
  const port = process.argv[2];
  const password = process.argv[3] || process.env.DDB_PASSWORD;
  if (port && password) {
    uri = `mongodb://docdb:${encodeURIComponent(password)}@127.0.0.1:${port}/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true`;
  } else {
    console.error("ERROR: set $env:MONGODB_URI or pass <port> <password> args");
    process.exit(1);
  }
}

console.log(`Target:     ${uri.replace(/:[^:@/]+@/, ":***@")}`);
console.log(`Database:   ${dbName}`);
console.log(`Collection: ${colName}`);
console.log(`Data file:  ${dataFile}`);

const client = new MongoClient(uri);
console.log("Reading data file...");
const docs = JSON.parse(readFileSync(dataFile, "utf-8"));
console.log(`Loaded ${docs.length} listings from disk`);

await client.connect();
const db = client.db(dbName);
const col = db.collection(colName);

console.log("Dropping existing collection (if any)...");
try { await col.drop(); } catch {}

const BATCH = 50;
let inserted = 0;
const t0 = Date.now();
for (let i = 0; i < docs.length; i += BATCH) {
  const batch = docs.slice(i, i + BATCH);
  await col.insertMany(batch, { ordered: false });
  inserted += batch.length;
  if (inserted % 200 === 0 || inserted === docs.length) {
    console.log(`  inserted ${inserted}/${docs.length} (${Math.round((Date.now() - t0)/1000)}s)`);
  }
}

console.log("");
console.log("=== Creating vector search index ===");
try {
  await db.command({
    createIndexes: colName,
    indexes: [{
      key: { descriptionVector: "cosmosSearch" },
      name: "vectorSearchIndex",
      cosmosSearchOptions: { kind: "vector-hnsw", similarity: "COS", dimensions: 1536 },
    }],
  });
  console.log("Vector index created");
} catch (e) {
  console.error("Vector index FAILED:", e.message);
}

console.log("=== Creating query indexes ===");
const queryIndexes = [
  { property_type: 1, price: 1 },
  { price: 1 },
  { bedrooms: 1, beds: 1 },
  { tags: 1 },
];
for (const k of queryIndexes) {
  try {
    const name = await col.createIndex(k);
    console.log(`  ${name}`);
  } catch (e) {
    console.error("  index FAILED:", JSON.stringify(k), e.message);
  }
}

const finalCount = await col.countDocuments();
const elapsed = Math.round((Date.now() - t0) / 1000);
console.log("");
console.log(`Data loaded in ${elapsed}s`);
console.log(`Total documents: ${finalCount}`);
console.log(`Vector index: vectorSearchIndex (HNSW, cosine, 1536 dim)`);
await client.close();
