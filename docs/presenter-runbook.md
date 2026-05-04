# Presenter runbook (60-minute flow)

Timing-oriented checklist aligned to the slide deck. **All examples use the
booking dataset (`demodb.stays`, 1,000 short-term-rental listings with 1536-dim
`text-embedding-3-small` vectors).**

> Quick mental model: the same `demodb.stays` collection is loaded in
> **local Docker → AKS → EKS** so the same queries work everywhere. Only the
> connection string changes.

## Pre-demo checklist

- [ ] DocumentDB VS Code extension installed
- [ ] `mongosh` on PATH
- [ ] Docker Desktop running
- [ ] GitHub repo opened (for the CI/CD slide)
- [ ] Multi-cloud stack up (`infra/multi-cloud/deploy.sh` + `deploy-documentdb.sh`)
      and the booking dataset loaded on the AKS primary (it replicates to EKS)
- [ ] Persistent port-forward tunnels running for both clusters
  (see `infra/scripts/portforward.sh` — defaults below)
- [ ] `OPENAI_API_KEY` exported in the shell you'll use for the vector demo
- [ ] kubectl contexts `azure-documentdb`, `aws-documentdb`, and `hub` configured

### Connection strings (paste-ready)

| Where | Connection string |
|---|---|
| Local Docker | `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256` |
| AKS primary (port-fwd) | `mongodb://default_user:<PASSWORD>@localhost:11260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256` |
| EKS replica (port-fwd) | `mongodb://default_user:<PASSWORD>@localhost:12260/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256` |

> Both clusters share the same DocumentDB credentials (one CR, one secret —
> Fleet propagates it). Get them with:
> `kubectl --context azure-documentdb -n documentdb-preview-ns get secret documentdb-credentials -o jsonpath='{.data.password}' | base64 -d`

> **Why port-forward for cloud clusters?** The gateway sidecar uses a self-signed
> cert with `CN=localhost`. The cloud LBs (Azure LB, AWS NLB) make the public
> TLS path flaky on first handshake. Port-forward bypasses the LB and just
> works. Run `infra/scripts/portforward.sh` (auto-restarts on drop, prints the
> ready URI). For EKS: `CONTEXT=eks-demo LOCAL_PORT=12260 ./portforward.sh`.

---

## Live demo script

### A) Local start (2–3 min)

Show `docker-compose.yml`, then:

```bash
docker compose up -d
docker ps
```

Talking points:
- Same image used in CI (next demo) and Kubernetes (later demos)
- Port `27017` mapped to the gateway's `10260`
- TLS on by default — `tlsAllowInvalidCertificates=true` for the demo cert

Then load the booking dataset (idempotent — skip if already loaded):

```bash
MONGODB_URI="mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" \
  ./data/load-data.sh
```

Result: `demodb.stays` with 1,000 documents, vector index, and four query indexes.

### B) VS Code connection (2–4 min)

In the **DocumentDB** panel:

1. **+ Add Connection** → paste the local connection string above
2. Label it `Local — docdb`
3. Expand `demodb` → `stays`

Highlight: same UX you'll use against the cloud clusters in section I.

### C) Data import + exploration (5 min)

In the extension, open `demodb.stays`. Toggle:

- **JSON view** — show document shape (`name`, `price`, `amenities`, `tags`,
  `descriptionVector`, `search_text`)
- **Tree view** — expand the `amenities` array
- **Table view** — sort by `price`

Talking point: `descriptionVector` is a 1536-dim embedding of `search_text`
generated with **OpenAI `text-embedding-3-small`**. Queries at runtime must
use the same model.

### D) Query editor (4 min)

Right-click `stays` → **Find** (or open the Documents view). Click the gear
and paste:

**Filter:**
```json
{ "property_type": "Entire home/apt", "price": { "$lt": 200 } }
```

**Project:**
```json
{ "_id": 0, "name": 1, "price": 1, "bedrooms": 1 }
```

**Sort:**
```json
{ "price": 1 }
```

Run. Show the results pane.

### E) Mongoshell (3 min)

Right-click the connection → **Launch Shell**:

```javascript
use demodb

// Find entire homes under $200
db.stays.find(
  { property_type: "Entire home/apt", price: { $lt: 200 } },
  { name: 1, price: 1, bedrooms: 1 }
).limit(5)

// Tag-based filter (multikey index on `tags`)
db.stays.find(
  { tags: { $all: ["downtown", "wifi"] } },
  { name: 1, tags: 1, price: 1 }
).limit(5)

// Aggregation: avg price per property type
db.stays.aggregate([
  { $group: { _id: "$property_type", avgPrice: { $avg: "$price" }, n: { $sum: 1 } } },
  { $sort: { avgPrice: -1 } }
])
```

### F) Indexing (4–6 min)

Show that the loader already created useful indexes:

```javascript
db.stays.getIndexes()
// _id_, vectorSearchIndex, property_type_1_price_1, price_1, bedrooms_1_beds_1, tags_1
```

Demo before/after on a query the indexes do **not** cover:

```javascript
// 1) No supporting index — COLLSCAN
db.stays.find({ bathrooms: { $gte: 3 }, price: { $lt: 400 } }).explain("executionStats")

// 2) Add a compound index
db.stays.createIndex({ bathrooms: 1, price: 1 })

// 3) Re-run — IXSCAN, far fewer docs examined
db.stays.find({ bathrooms: { $gte: 3 }, price: { $lt: 400 } }).explain("executionStats")
```

Compare `executionStats.executionTimeMillis` and `totalDocsExamined` before
and after.

### G) Vector search (5–6 min)

Show the index that ships with the dataset:

```javascript
db.stays.getIndexes().filter(i => i.name === "vectorSearchIndex")
// HNSW, cosine similarity, 1536 dim, on `descriptionVector`
```

Run a semantic search using a prebuilt embedding (avoids needing OpenAI live):

```bash
# In a Python REPL or scratch script
python - <<'PY'
import os, json
from openai import OpenAI
from pymongo import MongoClient

oai = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
emb = oai.embeddings.create(
    model="text-embedding-3-small",
    input="cozy downtown loft with hot tub and fast wifi for remote work"
).data[0].embedding

m = MongoClient("mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true")
results = m["demodb"]["stays"].aggregate([
    {"$search": {"cosmosSearch": {
        "vector": emb, "path": "descriptionVector", "k": 5
    }, "returnStoredSource": True}},
    {"$project": {"_id": 0, "name": 1, "price": 1,
                  "score": {"$meta": "searchScore"}}}
])
for r in results:
    print(f"{r['score']:.4f}  ${r['price']}/night  {r['name']}")
PY
```

Talking points:
- Same query embedded with `text-embedding-3-small` (must match the corpus)
- HNSW index on `descriptionVector`, cosine similarity
- Results ranked by `searchScore`

### H) CI/CD slide (3–5 min)

Open `.github/workflows/ci.yml`:

- DocumentDB runs as a **service container** alongside the test job
- Tests use `MONGODB_URI` — same env var as local + scripts
- Push → test against real DocumentDB → no cloud cost

### I) Kubernetes + multi-cloud (live, ~10 min)

Now the punchline: **one DocumentDB instance, two clouds, real replication, one
command to fail over.**

**Switch the VS Code connection** from `Local — docdb` to
`AKS — primary (port-fwd)`. Repeat the section E queries — identical results
to the local container.

```bash
# Terminal split — show both clusters and the Fleet hub
kubectl --context hub              get documentdb -n documentdb-preview-ns
kubectl --context azure-documentdb get pods       -n documentdb-preview-ns
kubectl --context aws-documentdb   get pods       -n documentdb-preview-ns
```

Point out: AKS pod is `documentdb-preview-1` (primary), EKS pod has label
`component=wal-replica` — streaming WAL via the Istio east-west gateways.

```javascript
// Connected to AKS via port-forward on localhost:11260
use demodb
db.stays.countDocuments()                    // 1000
db.stays.insertOne({ _id: "sentinel-talk", at: new Date() })

// Switch the VS Code connection to EKS (port-forward localhost:12260)
use demodb
db.stays.countDocuments()                    // 1000 — replicated from AKS
db.stays.find({ _id: "sentinel-talk" })      // shows up within ~2s
```

**Then fail over live:**

```bash
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace  documentdb-preview-ns \
  --hub-context hub \
  --target-cluster aws-documentdb \
  --cluster-context aws-documentdb
```

EKS becomes primary, AKS becomes replica. Insert another doc on EKS, see it
appear on AKS. Promote back if time permits.

Talking points:
- **Same operator, same chart, same DocumentDB** — driven by Azure Fleet Manager
- **Real WAL replication** over an Istio multi-cluster mesh (mTLS, east-west GW)
- **One command** to fail over — no DNS swap, no app config change required
- Application code: zero changes

---

## Fallbacks

- If port `27017` is busy, edit `docker-compose.yml` and adjust the URI.
- If a port-forward tunnel drops mid-demo, `infra/scripts/portforward.sh`
  auto-restarts within ~2s.
- If the cloud LBs *do* hold the TLS handshake on the day, you can demo the
  raw external IP/hostname — but the safe path is the port-forward.
- If the VS Code extension misbehaves, mongoshell does the same job from a
  terminal split.

## J) Cross-Cloud Failover Demo (Live App)

This section covers the optional "big red button" failover demo at the end of
the multi-cloud segment. The app lives in `app/failover-demo/` — see its
README for full setup. This section is the on-stage script.

**Prereqs (do this before going on stage):**

1. Multi-cloud cluster from `infra/multi-cloud/` is up; `kubectl documentdb`
   plugin on PATH.
2. Two port-forwards running (separate terminals):
   `kubectl --context azure-documentdb -n documentdb-preview-ns port-forward svc/documentdb-service-azure-documentdb 27018:10260`
   `kubectl --context aws-documentdb   -n documentdb-preview-ns port-forward svc/documentdb-service-aws-documentdb   27019:10260`
3. `app/failover-demo/clusters.json` filled in with the `docdb` password.
4. `cd app/failover-demo && npm install && npm run dev` (server :4000, web :5173).

**On-stage flow (~3 min):**

1. Open http://localhost:5173 on the projector. Confirm AKS green PRIMARY,
   EKS blue REPLICA, both reachable. Auto-insert is on at 2 Hz by default.
2. Narrate the architecture for ~30s while counters tick. Point out the
   replication lag number on the EKS panel.
3. Click 🔴 **FAILOVER AKS → EKS**. Read modal, click **Failover now**.
4. Narrate the streamed kubectl output: PROMOTING → RECONFIGURING → ROUTING.
5. When the strip turns green (~30–45 s): EKS is now PRIMARY (green), AKS is
   REPLICA (blue), and writes resume on EKS.
6. (Optional) Show the event log at the bottom — the writer never paused,
   only the *direction* changed.

**If it goes sideways:**

- Failover stuck on PROMOTING > 60s → the orchestrator times out and surfaces
  the error in the strip. Skip ahead; the static slide explains the mechanism.
- Both panels turn red mid-failover → port-forward dropped. Restart the
  port-forwards; the panels recover within ~2s.
- Auto-insert auto-pauses after 3 consecutive write failures. Toggle it back
  on after the failover completes if needed.

Failback (EKS → AKS) is the same button in reverse, *if* the demoted AKS
member has finished re-bootstrapping as a replica. See the app's README for
the open question on whether this is automatic.