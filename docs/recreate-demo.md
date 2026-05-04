# Recreate the demo (step-by-step)

This guide mirrors the talk flow:

1) local install (Docker)
2) connect with VS Code extension
3) import/query data
4) vector search
5) index advisor (extension feature)

## 1) Run DocumentDB Local

```bash
docker compose up -d
```

Confirm it is running:

```bash
docker ps
```

Connection string:

- `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true`

## 2) Connect via VS Code

1. Install **DocumentDB for VS Code** from the marketplace.
2. Open the DocumentDB view in the Activity Bar.
3. Add a new connection using the connection string: `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true`.
4. Name it `DocumentDB Local`.

## 3) Create database + collection

Using the extension:

- Create database: `foodservice` (already created by the seed step)
- Collections (already created by the seed step): `restaurants`, `restaurants_vectors`

If you don't see them right away, expand the connection and hit refresh.

## 4) Load sample data (two options)

### Option A — UI import (best for presentations)

- Import file: `data/restaurants.json` (raw) or `data/restaurants_vectors.json` (vectorized)
- Confirm you see hundreds of documents.

### Option B — script import (best for repeatability)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python .\scripts\generate_restaurants.py --count 5000 --hot-count 2000 --out .\data\restaurants.json
python .\scripts\load_restaurants.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --db foodservice --collection restaurants --file .\data\restaurants.json --drop

# Optional: generate vectorized dataset and load it into restaurants_vectors
python .\scripts\vectorize_restaurants_json.py --in-file .\data\restaurants.json --out-file .\data\restaurants_vectors.json
python .\scripts\load_restaurants.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --db foodservice --collection restaurants_vectors --file .\data\restaurants_vectors.json --drop
```

Note: the generator also creates synthetic `tags` and short `reviews` with `text` so vector-search queries can look natural.

## 5) Query demo snippets

Run scripted examples:

```powershell
python .\scripts\query_examples.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
```

Note: for a reliable before/after story, this script drops any non-`_id` indexes it finds on the collection before measuring the "before index" query.

Or paste these into the extension query editor:

```javascript
// Find all Italian restaurants
use foodservice

db.restaurants.find({ cuisine: "Italian" })

// Projection
db.restaurants.find(
  { cuisine: "Italian" },
  { name: 1, address: 1 }
)

// Operator query
db.restaurants.find({ "reviews.rating": { $gte: 5 } })

// Aggregation pipeline
// (zip code distribution)
db.restaurants.aggregate([
  { $match: { cuisine: "Italian" } },
  { $group: { _id: "$address.zipcode", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

## 6) Vector search demo

There are two options:

1) **Simple smoke demo** (tiny `products` dataset)
2) **Restaurants vector demo** (separate `restaurants_vectors` dataset with deterministic fake embeddings)

```powershell
python .\scripts\vector_demo.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
```

Notes:

- The script creates `foodservice.products`.
- It creates a `vector-hnsw` index on `vectorEmbedding` and runs a `$search` pipeline.
- The index uses `"similarity": "COS"` (cosine) to match DocumentDB's supported values.

### Option B — Restaurants vector search (deterministic fake embeddings)

This option uses a *separate* collection for vectors:

- Source: `foodservice.restaurants`
- Target: `foodservice.restaurants_vectors`

This separation is intentional: you can run the compound-index / Index Advisor demo on `restaurants`, then run vector search on `restaurants_vectors` without the two interfering.

Run:

```powershell
python .\scripts\vector_restaurants_demo.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true"
```

Tip: if `restaurants_vectors` was seeded by Docker Compose, the script will reuse it (and just ensure the vector index exists). Use `--drop` only if you want to rebuild the vector collection from `restaurants`.

If you like to demo score thresholds, try:

```powershell
python .\scripts\vector_restaurants_demo.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --query "cozy romantic date night pasta" --mode compact --filter-on cosine --k 20 --min-score 0.8 --drop
```

What it does:

- derives a stable `embeddingText` from each restaurant
- generates a deterministic `vectorEmbedding` (no external model)
- creates a `vector-hnsw` index on `vectorEmbedding`
- runs a `$search` query and prints ranked results

Note: `--mode rich` normalizes free-form queries into a structured string (e.g., `cuisine italian borough manhattan zipcode 10001`) so results are more intuitive. `--mode compact` keeps the query raw for high cosine similarity on a small tag-like vocabulary.

See [docs/vector-search-fake-embeddings.md](docs/vector-search-fake-embeddings.md) for details and rationale.

## 7) Index Advisor demo (extension feature)

Run a query that benefits from a compound index, e.g.:

```javascript
use foodservice

db.restaurants.find({
  cuisine: "Italian",
  "address.zipcode": "10001"
}).sort({ name: 1 })
```

Optional (scripted, repeatable before/after):

```powershell
python .\scripts\query_examples.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --repeats 30 --warmup 5
```

Tip: for a more dramatic timing difference, generate/load a larger dataset first:

```powershell
python .\scripts\generate_restaurants.py --count 20000 --hot-count 5000
python .\scripts\load_restaurants.py --uri "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" --file .\data\restaurants.json --drop
```

In the extension, open **Index Advisor** (or the equivalent insights/advisor UI) and apply the suggested compound index.

## 8) Optional: CI + Kubernetes + monitoring

- CI: see `.github/workflows/ci.yml`
- Kubernetes: see `k8s/`
- Monitoring: see `monitoring/`

## 9) Run the same demo against AKS (cloud)

Once `infra/azure/deploy.sh` has stood up the AKS cluster + DocumentDB instance
(see [demo/04-aks/README.md](../demo/04-aks/README.md)), you can connect the
VS Code DocumentDB extension to it and run the exact same queries as local.

### Why a port-forward (and not the public IP)?

The DocumentDB gateway uses a self-signed cert (CN=`localhost`) baked into the
image. Outside of the cluster, the Azure LoadBalancer in front of it can drop
the TLS handshake (LB health probes hammer the gateway with non-TLS pings, and
some clients stumble on the SNI mismatch). A `kubectl port-forward` skips the
LB entirely and gives you a clean, reliable tunnel — which is what the VS Code
extension wants.

You only need to do this if you want to drive the cloud instance from your
laptop. Apps running *inside* the cluster don't need it.

### Start a persistent port-forward

```bash
infra/scripts/portforward.sh
```

This:
- Reads the username/password from the `docdb-demo-credentials` secret
- Prints a ready-to-paste `mongodb://...@localhost:11260/...` URI
- Auto-restarts the tunnel if it drops (laptop sleep, idle timeout, pod
  restart) so you don't have to babysit it during a talk

Leave the terminal running. `Ctrl+C` to stop. Override `CONTEXT`,
`NAMESPACE`, `LOCAL_PORT`, etc. via env vars if needed.

### Add the connection in VS Code

1. **DocumentDB extension → + Add Connection**
2. Paste the URI printed by `portforward.sh`
3. Label it `AKS — docdb-demo (port-fwd)`

You can now run the same queries from sections 4–7 against the cloud instance.

