# Demo 02: Vector Search and Index Advisor

**Time: ~12 minutes**

> Uses the booking dataset (`demodb.stays`) with 1,536-dim
> `text-embedding-3-small` vectors in the `descriptionVector` field.

## What You'll Show

1. Vector index that already ships with the dataset
2. Run semantic similarity search
3. Use Index Advisor to optimize a slow query

## Vector Search (8 min)

### 1. Confirm the Vector Index

`data/load-data.sh` already created the HNSW index. Verify:

```javascript
use demodb
db.stays.getIndexes().filter(i => i.name === "vectorSearchIndex")
```

If you need to recreate it manually:

```javascript
db.runCommand({
  createIndexes: "stays",
  indexes: [{
    key: { "descriptionVector": "cosmosSearch" },
    name: "vectorSearchIndex",
    cosmosSearchOptions: {
      kind: "vector-hnsw",
      similarity: "COS",
      dimensions: 1536
    }
  }]
})
```

### 2. Run Semantic Search

```javascript
// Replace <QUERY_EMBEDDING> with the 1536-dim vector from the helper below
db.stays.aggregate([
  {
    $search: {
      cosmosSearch: {
        vector: <QUERY_EMBEDDING>,
        path: "descriptionVector",
        k: 5
      },
      returnStoredSource: true
    }
  },
  {
    $project: {
      _id: 0,
      name: 1,
      property_type: 1,
      price: 1,
      tags: 1,
      score: { $meta: "searchScore" }
    }
  }
])
```

### 3. Python Helper for Embeddings

Reads Azure OpenAI from `.env` (set up by `infra/azure/deploy-openai.sh`),
with a fallback to public OpenAI if `AZURE_OPENAI_*` isn't present.

```python
# demo/02-vector-search/search.py
import os
from pathlib import Path
from pymongo import MongoClient

# Load .env from repo root if present
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parents[2] / ".env")
except ImportError:
    pass  # pip install python-dotenv

EMBEDDING_MODEL = "text-embedding-3-small"  # MUST match the corpus

if os.environ.get("AZURE_OPENAI_ENDPOINT"):
    from openai import AzureOpenAI
    oai = AzureOpenAI(
        azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
        api_key=os.environ["AZURE_OPENAI_API_KEY"],
        api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21"),
    )
    EMBEDDING_DEPLOYMENT = os.environ.get(
        "AZURE_OPENAI_EMBEDDING_DEPLOYMENT", EMBEDDING_MODEL
    )
else:
    from openai import OpenAI
    oai = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    EMBEDDING_DEPLOYMENT = EMBEDDING_MODEL  # public OpenAI uses model name directly

client = MongoClient(
    "mongodb://demo:demo@localhost:27017/"
    "?tls=true&tlsAllowInvalidCertificates=true"
)
db = client["demodb"]

def search(query: str, k: int = 5):
    embedding = oai.embeddings.create(
        model=EMBEDDING_DEPLOYMENT,
        input=query,
    ).data[0].embedding

    results = db.stays.aggregate([
        {"$search": {"cosmosSearch": {
            "vector": embedding, "path": "descriptionVector", "k": k
        }, "returnStoredSource": True}},
        {"$project": {
            "_id": 0, "name": 1, "property_type": 1,
            "price": 1, "tags": 1,
            "score": {"$meta": "searchScore"}
        }}
    ])

    for r in results:
        print(f"  {r['score']:.4f} | ${r.get('price', '?')}/night | {r['name']}")

# Demo queries
search("cozy downtown loft with hot tub and fast wifi for remote work")
search("family-friendly home with kitchen and parking near the beach")
search("quiet mountain cabin with fireplace and pet friendly")
```

Install once: `pip install pymongo openai python-dotenv`

## Index Advisor (4 min)

### 4. Show a Slow Query

Pick a predicate the seeded indexes don't cover:

```javascript
// COLLSCAN — no supporting index for { bathrooms, price }
db.stays.find({
  bathrooms: { $gte: 3 },
  price: { $lt: 400 }
}).sort({ name: 1 }).explain("executionStats")
```

Note `executionStats.executionTimeMillis` and `totalDocsExamined`.

### 5. Apply Recommendation

```javascript
db.stays.createIndex({ bathrooms: 1, price: 1, name: 1 })
```

### 6. Re-run Query

```javascript
db.stays.find({
  bathrooms: { $gte: 3 },
  price: { $lt: 400 }
}).sort({ name: 1 }).explain("executionStats")
```

Expect: `IXSCAN`, dramatically lower `totalDocsExamined`, single-digit-ms times.

## Talking Points

- Vector search is built-in, not an add-on
- HNSW, IVF, and DiskANN index types available
- Index Advisor uses query patterns to recommend covering indexes
- Same vector search works locally and in production — the embeddings,
  index, and query syntax are identical
- The corpus and queries **must use the same embedding model**
  (`text-embedding-3-small` here)
