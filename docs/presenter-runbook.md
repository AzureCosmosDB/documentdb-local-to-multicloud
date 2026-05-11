# Presenter runbook (60-minute flow)

Timing-oriented checklist aligned to the slide deck. **All examples use the
booking dataset (`bookingsdb.listings`, 1,000 short-term-rental listings with
1536-dim `text-embedding-3-small` vectors).**

The companion collection `bookingsdb.bookings` is used for the multi-cloud
write/replication portion of the demo and is populated live by the monitor
app (`app/monitor-app/`).

> Quick mental model: the same `bookingsdb.listings` collection is loaded in
> **local Docker -> AKS -> EKS** so the same queries work everywhere. Only the
> connection string changes. Writes (new `bookings` documents) go to the AKS
> primary and stream over WAL to the EKS replica.

## Pre-demo checklist

- [ ] DocumentDB VS Code extension installed (with the AI Index Advisor)
- [ ] `mongosh` on PATH
- [ ] Docker Desktop running, no `documentdb-local` container yet
      (the demo starts from `docker compose up -d` on stage)
- [ ] GitHub repo opened (for the CI/CD slide)
- [ ] Multi-cloud stack up (`infra/multi-cloud/deploy.sh` +
      `deploy-documentdb.sh`) and `bookingsdb.listings` loaded on the AKS
      primary (it replicates to EKS automatically)
- [ ] Persistent port-forward tunnels running for both clusters
      (defaults: AKS=57017, EKS=57018)
- [ ] `OPENAI_API_KEY` exported in the shell you''ll use for the vector demo
- [ ] kubectl contexts `azure-documentdb`, `aws-documentdb`, and `hub`
      configured
- [ ] **AWS SSO logged in** within the last hour: `aws sso login` (token
      lifetime is 8-12h but SSO requires a browser handshake; if it expires
      mid-demo the monitor app's PRIMARY badge will flip to amber
      "Failover in progress" because `kubectl --context aws-documentdb`
      cannot reach the cluster). Verify with
      `kubectl --context aws-documentdb -n documentdb-preview-ns get cluster`.
- [ ] Monitor app running (`app/monitor-app/start.ps1`) - open
      <http://localhost:5174> on a second screen

### Multi-cloud deploy gotchas (read once before running deploy.sh)

These bit me on the dry-run and deploy.sh now auto-handles most of them, but keep them in mind:

1. **Both clusters must be K8s 1.35+** - DocumentDB operator v0.2.0 requires
   ImageVolume (GA in 1.35). On 1.34 the operator pod crashloops with a clear
   `requires Kubernetes 1.35+` setup error. `cluster-config.yaml` (EKS) and
   AKS provisioning both pin 1.35.
2. **`az fleet` extension version pin** - On az 2.65 the latest fleet
   extension (1.9.0) crashes; deploy.sh pins to 1.5.0.
3. **`kubelogin` must be on PATH** - Fleet hub is AAD-enabled. deploy.sh runs
   `kubelogin convert-kubeconfig -l azurecli --context hub` automatically.
4. **Helm >= 3.14 + Windows symlink fix** - kubefleet + fleet-networking helm
   charts ship CRDs as git symlinks. On Windows checkouts they materialise as
   text files containing the link target; helm then errors with
   `YAML parse error ... cannot unmarshal string into ... SimpleHead`.
   deploy.sh now restores the symlinks in-place before running helm.
5. **EKS cluster security group needs self-ingress** - Pod-to-pod traffic on
   AWS VPC CNI uses the cluster SG only. Without self-ingress, kube-system
   pods (CoreDNS, ebs-csi, metrics-server) crashloop. deploy.sh now adds the
   four required SG rules right after `eksctl create cluster`.
6. **Istio pinned to 1.23.4** - 1.24+ removed `IstioOperator` API used by
   `samples/multicluster/gen-eastwest-gateway.sh`. Override with
   `ISTIO_VERSION_OVERRIDE=...` if needed. On Windows, deploy.sh downloads
   `istio-${VER}-win.zip` directly (the `curl | sh` installer is Linux-only).
7. **Fleet RBAC propagation takes ~1-2 minutes.** First call may return
   `Forbidden`. Wait and retry.

### Connection strings (paste-ready)

| Where | Connection string |
|---|---|
| Local Docker | `mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&authMechanism=SCRAM-SHA-256` |
| AKS primary (port-fwd) | `mongodb://docdb:<PASSWORD>@127.0.0.1:57017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true` |
| EKS replica (port-fwd) | `mongodb://docdb:<PASSWORD>@127.0.0.1:57018/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true` |

> Both clusters share the same DocumentDB credentials (one CR, one secret -
> Fleet propagates it). Get them with:
> `kubectl --context azure-documentdb -n documentdb-preview-ns get secret documentdb-credentials -o jsonpath=''{.data.password}'' | base64 -d`

> **Why port-forward for cloud clusters?** The gateway sidecar uses a self-signed
> cert with `CN=localhost`. The cloud LBs (Azure LB, AWS NLB) make the public
> TLS path flaky on first handshake. Port-forward bypasses the LB and just
> works. Defaults are AKS=57017 and EKS=57018 to match the monitor app.

> **`directConnection=true` matters.** The DocumentDB gateway is a single
> mongos-compatible endpoint, not a replica set. Without `directConnection`,
> the driver does an SRV/replSet lookup against the gateway''s advertised
> hostname (`isdbgrid`) and fails with `ENOTFOUND`. The VS Code extension''s
> form has a "Direct connection" toggle - turn it on.

---

## Live demo script

### A) Local start (2-3 min)

Show `docker-compose.yml`, then:

```bash
docker compose up -d
docker compose ps
```

Talking points:
- Same image used in CI (next demo) and Kubernetes (later demos)
- Port `27017` mapped to the gateway's `10260`
- TLS on by default - `tlsAllowInvalidCertificates=true` for the demo cert
- The `seed-listings` sidecar runs once on first up: loads
  `data/listings_vectors.json` into `bookingsdb.listings`, then creates
  the cosmosSearch vector index + four query indexes, then exits.
  Idempotent on re-runs (skips if the collection already has documents).

Expect ~60-90s from `up -d` to a populated database. Verify before moving on:

```powershell
mongosh "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" `
  --quiet --eval "use('bookingsdb'); db.listings.countDocuments()"
# -> 1000
```

Result: `bookingsdb.listings` with 1,000 documents, `vectorSearchIndex`
(HNSW, cosine, 1536-dim), and four secondary indexes (`property_type+price`,
`price`, `bedrooms+beds`, `tags`).

> **Reload trick** (only if you need to re-seed without restarting the
> container — e.g. someone deleted a document mid-demo):
> `node scripts\load_listings.mjs`. Same dataset, same indexes, runs
> against an already-up container. (`scripts/load-data.sh` is the
> Linux/CI equivalent.)

### B) VS Code connection (2-4 min)

In the **DocumentDB** panel:

1. **+ Add Connection** -> paste this connection string:

   ```
   mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true
   ```

   ...or fill the form with:

   | Field | Value |
   |---|---|
   | Host | `localhost` |
   | Port | `27017` |
   | Username | `demo` |
   | Password | `demo` |
   | Auth database | `admin` |
   | TLS / SSL | enabled |
   | Allow invalid certificates | yes |
   | Direct connection | yes |

2. Label it `Local - docdb`
3. Expand `bookingsdb` -> `listings`

Highlight: same UX you''ll use against the cloud clusters in section I.

### C) Data import + exploration (3 min)

In the extension, open `bookingsdb.listings` and click into a single document
to show **JSON view**:

- Point out the human fields: `displayName`, `city`, `price`, `amenities[]`,
  `tags[]`, `property_type`
- Scroll down to `descriptionVector` and let it scroll for a beat - this is
  a **1,536-dim float array embedded directly in the document**. No separate
  vector store, no extra service to operate.

Talking point: `descriptionVector` is an embedding of `search_text`
generated with **OpenAI `text-embedding-3-small`**. Queries at runtime must
use the same model. We'll search against it in section G.

> Skip the Tree and Table views in the current extension build - tree
> doesn't expand arrays usefully, and the table doesn't sort. The query
> editor in section D is where filtering and sorting actually shine.

### D) Query editor (4 min)

Right-click `listings` -> **Find** (or open the Documents view). Click the gear
and paste:

**Filter:**
```json
{ "property_type": "Entire home", "price": { "$lt": 200 } }
```

**Project:**
```json
{ "_id": 0, "displayName": 1, "city": 1, "price": 1, "bedrooms": 1 }
```

**Sort:**
```json
{ "price": 1 }
```

Run. Show the results pane.

#### Generate a slow query for Query Insights

To populate the **Query Insights** tab with a query worth talking about, paste
this filter into the Query Editor (no projection or sort - just the filter).
It forces a COLLSCAN because the existing `bedrooms_1_beds_1` compound index
can't serve a standalone `beds` predicate (compound-prefix rule — `bedrooms`
has to be in the filter first), so the planner reads all 1,000 docs:

```json
{ "beds": 4 }
```

> Returns 57 hits, examines 1,000 docs, ~20-40 ms. Run it 2-3 times so it
> shows up clearly in Query Insights with a frequency count.

Now open **Query Insights** on the connection. Talking points:

- The slow `beds` query is at the top of the list - high `docsExamined`, low
  `docsReturned`, no index used
- Compare against the indexed `property_type + price` query above - that one
  hits the compound index (`IXSCAN`) and barely registers
- Real-world: this is how teams find the queries that secretly cost them
  money. The AI Index Advisor (section F) takes this further by recommending
  the index to fix it.

> **Sidebar — why we don't demo a regex here.** It's tempting to use
> `{ search_text: { $regex: "rooftop", $options: "i" } }` for the slow case,
> but it's a trap: the advisor will suggest a single-field B-tree index on
> `search_text`, the planner will pick it, and the query gets **slower**
> (the regex still has to be tested against every index entry, plus a doc
> fetch per candidate). Unanchored case-insensitive substring search needs a
> `$text` index or vector search, not a B-tree. Save substring queries for
> the vector demo in section G.


### E) Mongoshell (3 min)

Right-click the connection -> **Launch Shell**, or open a fresh terminal and run:

```powershell
mongosh "mongodb://demo:demo@localhost:27017/bookingsdb?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
```

Then:

```javascript
use bookingsdb
```

Find entire homes under $200:

```javascript
db.listings.find(
  { property_type: "Entire home", price: { $lt: 200 } },
  { displayName: 1, city: 1, price: 1, bedrooms: 1 }
).limit(5)
```

Tag-based filter (multikey index on `tags`):

```javascript
db.listings.find(
  { tags: { $all: ["downtown", "wifi"] } },
  { displayName: 1, tags: 1, price: 1 }
).limit(5)
```

Aggregation - average price per property type:

```javascript
db.listings.aggregate([
  { $group: { _id: "$property_type", avgPrice: { $avg: "$price" }, n: { $sum: 1 } } },
  { $sort: { avgPrice: -1 } }
])
```

Aggregation - listings per city:

```javascript
db.listings.aggregate([
  { $group: { _id: "$city", n: { $sum: 1 }, avgPrice: { $avg: "$price" } } },
  { $sort: { n: -1 } },
  { $limit: 10 }
])
```

### F) Indexing + AI Index Advisor (4-6 min)

Show that the loader already created useful indexes. In **mongosh**:

```javascript
db.listings.getIndexes()
```

> Expect: `_id_`, `vectorSearchIndex`, `property_type_1_price_1`, `price_1`, `bedrooms_1_beds_1`, `tags_1`

Demo before/after on a query the indexes do **not** cover. Run the filter from
the **Query Editor** in the DocumentDB extension so the run shows up in Query
Insights and the Index Advisor:

```json
{ "bathrooms": 3 }
```

> Returns 28 hits, examines all 1,000 docs (full COLLSCAN). 36x amplification -
> the optimizer is reading 36 documents for every row it returns. Run it 2-3
> times.

Open **Query Insights** - the run shows COLLSCAN with `docsExamined: 1000`
vs `docsReturned: 28`.

**AI Index Advisor:** Click the **Index Advisor** tab (lightbulb icon) on the
listings collection. The advisor sees the slow run from Query Insights and
recommends `{ bathrooms: 1 }`. Click **Create index** - no mongosh, no DDL.

Re-run the same filter from the Query Editor. Query Insights now shows IXSCAN
with `docsExamined: 28` - 36x fewer reads, ~10x faster. Compare
`executionTimeMillis` and `totalDocsExamined` before and after.

> Caveat - say this on stage: "On 1,000 documents you won''t see dramatic
> recommendations because the dataset is too small for the optimizer to
> care. In a real workload - millions of documents and active query
> telemetry - the advisor watches your slow queries and suggests indexes
> with explain-plan justifications and projected gain."

### G) Vector search (5-6 min)

Show the index that ships with the dataset:

```javascript
db.listings.getIndexes().filter(i => i.name === "vectorSearchIndex")
// HNSW, cosine similarity, 1536 dim, on `descriptionVector`
```

Run a semantic search using OpenAI `text-embedding-3-small` (must match the
model used to build the corpus):

```bash
# In a Python REPL or scratch script
python - <<''PY''
import os
from openai import OpenAI
from pymongo import MongoClient

oai = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
emb = oai.embeddings.create(
    model="text-embedding-3-small",
    input="cozy downtown loft with hot tub and fast wifi for remote work"
).data[0].embedding

m = MongoClient("mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true")
results = m["bookingsdb"]["listings"].aggregate([
    {"$search": {"cosmosSearch": {
        "vector": emb, "path": "descriptionVector", "k": 5
    }, "returnStoredSource": True}},
    {"$project": {"_id": 0, "displayName": 1, "city": 1, "price": 1,
                  "score": {"$meta": "searchScore"}}}
])
for r in results:
    print(f"{r[''score'']:.4f}  ${r[''price'']}/night  {r[''city'']:<14}  {r[''displayName'']}")
PY
```

Talking points:
- Same query embedded with `text-embedding-3-small` (must match the corpus)
- HNSW index on `descriptionVector`, cosine similarity
- Results ranked by `searchScore`

### H) CI/CD slide (3-5 min)

Open `.github/workflows/ci.yml`:

- DocumentDB runs as a **service container** alongside the test job
- Tests use `MONGODB_URI` - same env var as local + scripts
- Push -> test against real DocumentDB -> no cloud cost

### I) Kubernetes + multi-cloud (live, ~10 min)

Now the punchline: **one DocumentDB instance, two clouds, real replication, one
command to fail over.**

**First, add the two cloud connections in the VS Code DocumentDB extension.**
If you have stale `AKS` / `EKS` profiles from earlier runs, right-click each
and **Remove Connection** before re-adding (old profiles can pin to defunct
ports). Then click **+ Add Connection** and paste the connection string:

**AKS - primary:**
```
mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true
```

**EKS - replica:**
```
mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57018/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true
```

...or fill the form with:

| Field | AKS - primary | EKS - replica |
|---|---|---|
| Name | `AKS - primary (port-fwd)` | `EKS - replica (port-fwd)` |
| Host | `127.0.0.1` | `127.0.0.1` |
| Port | **`57017`** | **`57018`** |
| Username | `docdb` | `docdb` |
| Password | `f4e7723a9db8f333f35257ad61225384` | same |
| Auth database | `admin` | `admin` |
| TLS | on | on |
| Allow invalid certs | on | on |
| Direct connection | **on** (mandatory) | **on** (mandatory) |
| Replica set | *(blank)* | *(blank)* |
| SRV | off | off |

> The two ports (57017 / 57018) match the persistent port-forwards already
> running and the monitor app's defaults. If you get `ECONNREFUSED 127.0.0.1:<port>`,
> the port-forward died - relaunch it (see the troubleshooting section).
> If you get `ENOTFOUND isdbgrid`, **Direct connection** is off - flip it on.

**Switch the VS Code connection** from `Local - docdb` to
`AKS - primary (port-fwd)`. Repeat the section E queries on `listings` -
identical results to the local container.

```bash
# Terminal split - show both clusters and the Fleet hub
kubectl --context hub              get documentdb -n documentdb-preview-ns
kubectl --context azure-documentdb get pods       -n documentdb-preview-ns
kubectl --context aws-documentdb   get pods       -n documentdb-preview-ns
```

Point out: AKS pod is `documentdb-preview-1` (primary), EKS pod has label
`component=wal-replica` - streaming WAL via the Istio east-west gateways.

Connected to AKS via port-forward on `127.0.0.1:57017` (or open a fresh terminal):

```powershell
mongosh "mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57017/bookingsdb?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
```

```javascript
use bookingsdb
```

```javascript
db.listings.countDocuments()
```

```javascript
db.bookings.insertOne({
  _id: "sentinel-talk",
  guest_name: "Stephen Strange",
  listing_display_name: "sanity check",
  city: "Denver",
  status: "confirmed",
  ts: new Date()
})
```

Now switch the VS Code connection to **EKS** (port-forward `127.0.0.1:57018`), or in a fresh terminal:

```powershell
mongosh "mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57018/bookingsdb?tls=true&tlsAllowInvalidCertificates=true&directConnection=true"
```

Then:

```javascript
use bookingsdb
```

```javascript
db.listings.countDocuments()
```

> Expect: `1000` - replicated from AKS

```javascript
db.bookings.findOne({ _id: "sentinel-talk" })
```

> Expect: shows up within ~200 ms

**Switch to the monitor app** (<http://localhost:5174>) for the visual punch:

- Both panels green, AKS labelled PRIMARY, EKS labelled REPLICA
- Click **+ Add booking** -> row pops on AKS, then on EKS with a `+~150ms`
  replication-lag badge
- Click **+ Add x10** for a clearer effect
- Talk track: server-measured lag is real WAL lag from primary commit to
  replica visibility

**Then fail over live:**

```bash
kubectl documentdb promote \
  --documentdb documentdb-preview \
  --namespace  documentdb-preview-ns \
  --hub-context hub \
  --target-cluster aws-documentdb \
  --cluster-context aws-documentdb
```

EKS becomes primary, AKS becomes replica. Insert another booking from the
monitor app - it now lands on EKS first and lags into AKS. Promote back if
time permits.

Talking points:
- **Same operator, same chart, same DocumentDB** - driven by Azure Fleet Manager
- **Real WAL replication** over an Istio multi-cluster mesh (mTLS, east-west GW)
- **One command** to fail over - no DNS swap, no app config change required
- Application code: zero changes - the monitor app uses the standard
  MongoDB driver against a port-forwarded gateway

---

## Fallbacks

- If port `27017` is busy, edit `docker-compose.yml` and adjust the URI.
- If a port-forward tunnel drops mid-demo, restart it; the monitor app
  reconnects automatically within ~5s.
- If the cloud LBs *do* hold the TLS handshake on the day, you can demo the
  raw external IP/hostname - but the safe path is the port-forward.
- If the VS Code extension misbehaves, mongoshell does the same job from a
  terminal split.

## J) Cross-cloud failover demo (live monitor app)

This is the "big red button" failover demo at the end of the
multi-cloud segment. The app lives in `app/monitor-app/` - see its README
for full setup. This section is the on-stage script.

> **DO ONE FAILOVER ON STAGE. Do not fail back live.**
>
> Postgres physical replication forks the WAL timeline on every promote.
> After a single bidirectional swap (A->B->A), the demoted side cannot
> resume streaming - it needs a `pg_basebackup` rebuild (~3-4 min). That
> is fine off-stage; awful on-stage. Issue
> [#375](https://github.com/documentdb/documentdb-kubernetes-operator/issues/375)
> in the operator tracks this.
>
> Single failover from your starting primary -> other cloud is rock solid.
> Pick a starting primary in pre-flight; if it's wrong, do an off-stage
> failover *before* the talk so the live one points the direction you
> rehearsed.

**Pre-flight (30 min before stage):**

1. Multi-cloud cluster from `infra/multi-cloud/` is up; `kubectl documentdb`
   plugin on PATH.
2. `aws sso login --sso-session cosmos` - the SSO token expires every
   ~12 hours.
3. `bookingsdb.listings` loaded on the desired starting primary
   (replicated to the other cloud).
4. `app/monitor-app/start.ps1` running (server :5174). The app spawns its
   own kubectl port-forwards to each gateway - no manual port-forward
   terminals needed.
5. Open <http://localhost:5174>: confirm both clusters green 3/3, the
   correct cloud shows PRIMARY/Writeable, and the **Bookings** tab
   loads (cold start can take ~10s on first visit; visit it now so it's
   warm).
6. Click **Reset (drop bookings)** then **Seed sample bookings** to
   leave a clean baseline.
7. (If your starting primary is on the wrong cloud) do one off-stage
   failover *now* so the live demo runs in the direction you rehearsed.

**On-stage flow (~3 min):**

1. Open <http://localhost:5174> on the projector. Confirm AKS green PRIMARY,
   EKS blue REPLICA, both reachable.
2. Click **Seed sample bookings** to prime a few rows. Narrate the
   architecture for ~30s while rows render on both panels.
3. Click **+ Add booking** a few times. Each booking samples a real listing
   from `bookingsdb.listings` and assigns a random Marvel guest. Point out
   the `+~150ms` replication-lag badge on the EKS panel.
4. (Optional) Click **+ Add x10** for a stress micro-burst.
5. Run the failover command in a side terminal:
   ```bash
   kubectl documentdb promote \
     --documentdb documentdb-preview \
     --namespace  documentdb-preview-ns \
     --hub-context hub \
     --target-cluster aws-documentdb \
     --cluster-context aws-documentdb
   ```
6. Within ~30-45s the panels swap roles: EKS becomes PRIMARY (green), AKS
   becomes REPLICA (blue). Click **+ Add booking** again - writes now land
   on EKS first.
7. Click **Reset (drop bookings)** to leave a clean slate. The drop replicates
   so both panels clear simultaneously.

**If it goes sideways:**

- Failover stuck on PROMOTING > 60s -> the strip surfaces the error. Skip
  ahead; the static slide explains the mechanism.
- A panel turns red mid-failover -> port-forward reconnecting. The app
  retries the tunnel automatically; usually recovers within ~5s.
- Insert errors -> check that the *current* primary panel is green. The app
  always writes to whichever member shows `role: primary` in the status
  endpoint, so promote/demote toggles which side accepts writes.
- **New primary is healthy but writes are slow / hang** -> two distinct
  causes, both worth knowing:
  1. **Stale promotion token** on the cluster you just promoted. Watch for
     `Cluster is unrecoverable` / `Promotion token content is not correct`.
     The monitor app surfaces a **Clear stale token** button that runs the
     one-line CNPG patch for you (`kubectl patch cluster.postgresql.cnpg.io
     <name> --type=json -p '[{"op":"remove","path":"/spec/replica/promotionToken"}]'`).
  2. **Synchronous-commit quorum across clouds.** The DocumentDB operator
     defaults to `dataDurability: required` with the cross-cloud peer in
     `standbyNamesPre`, so every commit waits for a cross-cloud ack. That
     gives you bulletproof durability but tens-to-hundreds of ms per write.
     For a demo (or any workload that can tolerate async cross-cloud
     replication) flip the new primary to `preferred` with local-only sync
     standbys -- writes commit on a local replica ack and cross-cloud
     replication continues asynchronously in the background:
     ```bash
     kubectl --context <primary-context> -n documentdb-preview-ns patch \
       cluster.postgresql.cnpg.io <cnpg-cluster-name> --type=json -p '[
         {"op":"replace","path":"/spec/postgresql/synchronous/dataDurability","value":"preferred"},
         {"op":"replace","path":"/spec/postgresql/synchronous/standbyNamesPre","value":[]},
         {"op":"replace","path":"/spec/postgresql/synchronous/number","value":1}
       ]'
     ```
     Pre-apply the same patch on the *replica* side too, so the next
     failover lands on a cluster that's already configured this way.

  > The monitor app's `/api/promote` handler now does both of these
  > automatically: 6s after a successful promotion it loops up to 4x
  > clearing any re-stamped `promotionToken` and re-applying the fast-write
  > sync profile. You shouldn't normally need the manual patch, but the
  > snippets above are the ground truth if the auto-reconcile is disabled.

- **New primary stuck `unrecoverable` with `Promotion token content is not
  correct for current instance` (upstream bug
  [documentdb/documentdb-kubernetes-operator#375](https://github.com/documentdb/documentdb-kubernetes-operator/issues/375)).**
  The operator's cross-cloud promote handshake captures the source-side
  promotion token at moment T and stamps it onto the target's
  `spec.replica.promotionToken`. After any prior failover the timelines
  have diverged, so CNPG rejects the token and parks the cluster as
  `unrecoverable`. The operator does not retry or back off.
  - **Auto-recovery (built into `/api/promote`).** After firing the promote,
    the handler now spawns a background healer (`healStaleTokenIfNeeded`)
    that polls the new primary for up to 3 minutes. If it sees the
    unrecoverable + stale-token state, it reads the *new primary's* own
    promotion-token ConfigMap (`<cluster>-promotion-token`, key
    `index.html` -- yes, really) and repeatedly stamps that local token
    onto `spec.replica.promotionToken` until CNPG accepts it (typically
    1-3 retries). You should usually not need to touch this on stage.
  - **Manual fallback (the red panic chain).** If the auto-heal hasn't
    cleared things within ~60s:
    1. Click the **Force-promote (local token)** button that appears on
       the unrecoverable cluster's card. This calls
       `/api/force-promote-local-token` which does the same patch as the
       healer but in one shot.
    2. If that returns ok but the cluster still doesn't recover, the
       local CM is itself stale (separate sidecar bug -- the CM doesn't
       refresh after the cluster has been rebuilt). Click **Rebuild
       replica** on the *current* primary candidate so it bootstraps
       fresh from `pg_basebackup`, wait ~3-5 min for it to come up
       healthy, then re-attempt the failover. The freshly-bootstrapped
       cluster will have a current CM token.
    3. Worst case, the same recovery sequence works from the CLI (each
       step is one of the API endpoints above):
       ```bash
       # 1. flip hub primary
       kubectl --context hub -n documentdb-preview-ns patch documentdb \
         documentdb-preview --type=merge \
         -p '{"spec":{"clusterReplication":{"primary":"<NEW>-documentdb"}}}'
       # 2. read NEW's local promotion token, stamp onto its own spec.replica
       TOK=$(kubectl --context <NEW> -n documentdb-preview-ns get cm \
         <cnpg-cluster>-promotion-token -o jsonpath='{.data.index\.html}')
       kubectl --context <NEW> -n documentdb-preview-ns patch \
         cluster.postgresql.cnpg.io <cnpg-cluster> --type=merge \
         -p "{\"spec\":{\"replica\":{\"promotionToken\":\"$TOK\"}}}"
       # 3. clear once accepted
       kubectl --context <NEW> -n documentdb-preview-ns patch \
         cluster.postgresql.cnpg.io <cnpg-cluster> --type=json \
         -p '[{"op":"remove","path":"/spec/replica/promotionToken"}]'
       # 4. rebuild OLD as fresh replica
       kubectl --context <OLD> -n documentdb-preview-ns delete \
         cluster.postgresql.cnpg.io <cnpg-cluster>
       ```
  - **Tracking.** A scheduled Clawpilot automation watches issue #375 daily
    and pings me when there's maintainer activity. When the upstream fix
    lands, rip out `healStaleTokenIfNeeded` and the force-promote button
    -- they are workarounds, not the architecture.

- **Replica gets stuck after rapid back-to-back failovers (WAL timeline
  divergence).** Symptom: the new replica's `pg_stat_wal_receiver` shows
  no rows (or `status != 'streaming'`), and the pod logs contain something
  like `FATAL: requested starting point X/Y on timeline N is not in this
  server's history. DETAIL: This server's history forked from timeline N
  at A/B`. PostgreSQL replication uses **timelines**, and each promotion
  increments the timeline. If we promote A->B->A in quick succession, the
  old primaries can end up on incompatible WAL forks that pure log replay
  can't bridge. CNPG's preview-operator wrapper does **not** auto-`pg_rewind`
  the demoted primary before re-attaching it, so the WAL receiver crashes
  and stays down.
  - **Prevention (built into the monitor app).** The Promote button is now
    gated on `replicationHealthy` — it disables itself with a tooltip
    explanation while the previous failover hasn't fully settled. The
    `/api/promote` handler also returns HTTP 409 if you try to bypass via
    curl. This single fix makes WAL divergence very unlikely on stage.
  - **Recovery (also built into the monitor app).** The replica card has a
    red **Rebuild replica** button. It hits `/api/rebuild-replica`, which
    deletes the replica's `cluster.postgresql.cnpg.io` resource. The
    DocumentDB hub operator reconciles within ~5s and re-creates the
    cluster, which triggers a fresh `pg_basebackup` from the current
    primary via the replica's `externalCluster` source. Total time from
    click to replica-streaming is ~2-3 min for the demo dataset. The
    button refuses to wipe the cluster that's currently primary.

### Why this demo keeps replicas running on **both** clouds

This setup runs `instancesPerNode: 3` on both AKS and EKS, so each cluster
already has its full HA replica set warm at all times. That means failover
is genuinely instant: the new primary's HA pods are already up, sync-commit
quorum is met immediately, and writes never block.

**You don't have to do this.** A common production topology is:
*N* HA replicas in the primary region, **1** instance in the standby region.
That cuts steady-state cost in half, and is fine if you're willing to accept
a brief write pause on the new primary while it scales out its HA replicas
after a failover (the operator does this automatically). Pick whichever
trade-off fits the workload:

| Topology                             | Steady-state cost | Failover write-pause |
| ------------------------------------ | ----------------- | -------------------- |
| 3 + 3 (this demo)                    | 2x                | ~0s                  |
| 3 + 1 (asymmetric, common in prod)   | 1.3x              | ~60-90s              |
| 1 + 1 (cheap, no per-region HA)      | 1x                | ~60-90s + restart    |

Toggle on the hub:
```bash
kubectl --context hub -n documentdb-preview-ns patch dbs.documentdb.io documentdb-preview \
  --type=merge -p '{"spec":{"instancesPerNode":3}}'
```

> **Preview operator caveat (May 2026):** the hub-level `instancesPerNode`
> field is honored by the DocumentDB operator only on the **primary**
> member. The replica member still gets `spec.instances: 1` on its CNPG
> cluster. To keep both clouds at 3 instances, also patch the CNPG cluster
> directly on the replica side:
>
> ```bash
> kubectl --context <replica-context> -n documentdb-preview-ns patch \
>   cluster.postgresql.cnpg.io <cnpg-cluster-name> \
>   --type=merge -p '{"spec":{"instances":3}}'
> ```
>
> The CNPG cluster name is the random suffix one shown in the monitor app's
> Topology tab (e.g. `documentdb-preview-787357054d2b4540`). The DocumentDB
> operator does not currently reconcile this field back, but re-apply the
> patch after every failover until the operator catches up.

Failback (EKS -> AKS) is the same `kubectl documentdb promote` command with
`--target-cluster azure-documentdb`, *if* the demoted AKS member has finished
re-bootstrapping as a replica.


## K) Observability tour with Grafana (3-4 min, optional but high-value)

Both clusters run **kube-prometheus-stack** + a standalone **postgres-exporter**
sidecar pair (one for the CNPG primary `-rw` service, one for the `-ro`
replicas). A pre-loaded dashboard called **DocumentDB Failover Overview**
is wired to fire automatically when you click the start.ps1-launched
Grafana tabs.

| Cluster | Grafana URL                                                                                       | Login                                            |
|---------|---------------------------------------------------------------------------------------------------|--------------------------------------------------|
| Azure   | http://40.70.169.198                                                                              | anonymous Viewer; `admin / techorama2026` to edit |
| AWS     | http://a6d5c0d8966584a85a1e540671a3132b-947608160.us-west-2.elb.amazonaws.com                     | same                                              |

**Demo beats:**

1. Open both Grafana tabs side-by-side. Point out the 9 panels:
   - **Cluster role** (stat) — green PRIMARY on one, blue REPLICA on the other.
   - **WAL position** — same LSN on both when healthy, diverges during failover.
   - **DB size**, **active backends**, **TPS**, **tuple ops** — workload signal.
   - **Replication lag bytes / seconds**, **WAL receiver up/down** — failover signal.
   - **Connections by state** — pool pressure during the load test.
2. Walk to the Load tab on the monitor app, pick **Morning** preset (50 RPS),
   and within ~10s the **TPS** and **tuple ops** panels light up on the
   current primary's cloud.
3. Trigger a failover from the monitor's Topology tab. Within 30-60s:
   - The **Cluster role** panel on the new primary flips PRIMARY (green).
   - **Replication lag seconds** spikes briefly on the new replica then settles.
   - **WAL receiver up** drops to 0 on the old primary, comes back up as
     replica.

> **Operator gotcha (May 2026 preview):** CNPG's built-in metrics exporter
> hits a `permission denied for schema documentdb_core` error on every
> query because the documentdb extension's auth hook fires on the BIND
> phase of `pgx`'s named prepared statements. We deploy
> `prometheuscommunity/postgres-exporter` (lib/pq, no prepared statements)
> instead. The `cnpg_monitor` role + grants are already replicated via
> WAL — you do **not** need to recreate them after a failover.

## L) Load tester (Load tab in the monitor app)

The Load tab simulates a realistic bookings site mix against the **current
primary** so the Grafana panels (and the monitor's own Bookings tab) have
something to show during a failover demo.

| Operation | Mix  | Target collection            | What it does                           |
|-----------|------|------------------------------|----------------------------------------|
| browse    | 80%  | `bookingsdb.listings`        | `find {city, price<=X}` sort+limit 20  |
| detail    | 15%  | `bookingsdb.listings`        | `findOne by _id` from sample cache     |
| insert    | 4%   | `bookingsdb.loadgen_bookings`| insert one fake booking                |
| update    | 1%   | `bookingsdb.loadgen_bookings`| confirm a recent loadgen booking       |

The writer collection (`loadgen_bookings`) is **separate** from the demo
Bookings tab's `bookings` collection so the on-screen Bookings list stays
clean and readable; the load tester never pollutes it.

**Presets** (RPS slider 0-500):
- **Idle** (5 RPS) — quiet baseline, just enough to keep panels alive.
- **Morning** (50 RPS) — cruising load, recommended for the failover demo.
- **Peak** (150 RPS) — visible commit/TPS activity on Grafana.
- **Black Friday** (400 RPS) — stress mode; only run if pool sizes are
  generous on the primary (see `maxPoolSize` in `server.js`).

**Demo beats:**

1. Drop the writer collection first via **Drop loadgen_bookings** so the
   `total_ops` counter starts clean.
2. Pick a preset (or set a custom RPS), click **Start**.
3. Watch **observed_rps** climb to match the slider value within ~5s, and
   **p50/p95/p99 latency** stay below ~50ms on a healthy cluster.
4. During a failover, p95/p99 spike briefly (3-10s) and the per-op error
   counts tick up; once the new primary is writeable, latencies recover.

> **Tuning notes:**
> - Pool size: `maxPoolSize: 32, minPoolSize: 2` in `server.js`. Bump to
>   64+ if you sustain >200 RPS with high latency.
> - The listings sample cache TTL is 5 minutes (500 docs). If you reseed
>   `listings` mid-demo, restart the monitor app to pick up fresh `_id`s.

