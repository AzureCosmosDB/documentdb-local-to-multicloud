/**
 * DocumentDB multi-cloud monitor + failover dashboard.
 *
 * Talks to the DocumentDB Mongo gateway (port 10260) on each member cluster
 * via persistent kubectl port-forwards.
 *
 * Required environment variables:
 *   DDB_NAMESPACE         e.g. documentdb-preview-ns
 *   DDB_RESOURCE          name of the DocumentDB CR (e.g. documentdb-preview)
 *   DDB_HUB_CONTEXT       kube context for the Fleet hub
 *   DDB_MEMBER_CONTEXTS   comma-separated kube contexts for member clusters
 *
 * Optional:
 *   PORT                  default 5174
 *   KUBECTL_BIN           default "kubectl"
 *   DDB_GATEWAY_USER      default "docdb"
 *   DDB_DEMO_DATABASE     mongo db name used for the data-replication tab (default "bookingsdb")
 *   LOCAL_MONGODB_URI     local Docker mongo for the Vector Search tab
 *                         (default: mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true)
 *   AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_API_KEY, AZURE_OPENAI_EMBEDDING_DEPLOYMENT,
 *   AZURE_OPENAI_API_VERSION  - powers /api/vector-search (loaded from .env at repo root)
 *   OPENAI_API_KEY        - alternative path for /api/vector-search (uses public OpenAI)
 */
// Load .env from repo root (two levels up from this file: app/monitor-app/server.js -> repo root)
const express = require("express");
const { spawn } = require("child_process");
const path = require("path");
const { MongoClient } = require("mongodb");
const { LoadGen, MAX_RPS } = require("./loadgen");
try { require("dotenv").config({ path: path.join(__dirname, "..", "..", ".env") }); } catch (_) {}

function required(name) {
  const v = process.env[name];
  if (!v || !v.trim()) { console.error(`Missing required env var: ${name}`); process.exit(1); }
  return v.trim();
}

const PORT = process.env.PORT || 5174;
const NAMESPACE = required("DDB_NAMESPACE");
const RESOURCE = required("DDB_RESOURCE");
const HUB_CONTEXT = required("DDB_HUB_CONTEXT");
const KUBECTL = process.env.KUBECTL_BIN || "kubectl";
const GATEWAY_USER = process.env.DDB_GATEWAY_USER || "docdb";
const DEMO_DB = process.env.DDB_DEMO_DATABASE || "bookingsdb";
const LISTINGS_COLL = "listings";
const BOOKINGS_COLL = "bookings";
const GATEWAY_PORT = 10260;
const GATEWAY_SVC = `documentdb-service-${RESOURCE}`;
const CREDENTIALS_SECRET = "documentdb-credentials";

const MEMBER_CONTEXTS = required("DDB_MEMBER_CONTEXTS")
  .split(",").map((s) => s.trim()).filter(Boolean);
if (MEMBER_CONTEXTS.length === 0) { console.error("DDB_MEMBER_CONTEXTS empty"); process.exit(1); }

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

function run(cmd, args, { timeoutMs = 60_000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { shell: false });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { try { child.kill("SIGKILL"); } catch (_) {} }, timeoutMs);
    child.stdout.on("data", (b) => (stdout += b.toString()));
    child.stderr.on("data", (b) => (stderr += b.toString()));
    child.on("close", (code) => { clearTimeout(timer); resolve({ code: code ?? -1, stdout, stderr }); });
    child.on("error", (err) => { clearTimeout(timer); resolve({ code: -1, stdout, stderr: stderr + String(err) }); });
  });
}
function kubectl(args, opts) { return run(KUBECTL, args, opts); }
function fromB64(s) { return Buffer.from(s, "base64").toString("utf8"); }

async function getDocumentDB() {
  const res = await kubectl([
    "--context", HUB_CONTEXT, "-n", NAMESPACE,
    "get", "documentdb", RESOURCE, "-o", "json",
  ]);
  if (res.code !== 0) throw new Error(`get documentdb: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

async function findCNPGCluster(ctx) {
  const res = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "get", "cluster.postgresql.cnpg.io", "-o", "json",
  ]);
  if (res.code !== 0) return null;
  const j = JSON.parse(res.stdout);
  if (!j.items || j.items.length === 0) return null;
  // Prefer the cluster that actually has a -rw service
  for (const c of j.items) {
    const svc = await kubectl([
      "--context", ctx, "-n", NAMESPACE,
      "get", "svc", `${c.metadata.name}-rw`, "--ignore-not-found", "-o", "name",
    ]);
    if (svc.code === 0 && (svc.stdout || "").trim()) return c;
  }
  return j.items[0];
}

// ---------- Status / failover endpoints (unchanged shape) ----------
async function getServiceLBHost(ctx) {
  const out = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "get", "svc", GATEWAY_SVC, "--ignore-not-found", "-o", "json",
  ]);
  if (out.code !== 0 || !out.stdout) return null;
  try {
    const svc = JSON.parse(out.stdout);
    const ing = svc?.status?.loadBalancer?.ingress?.[0];
    return ing?.hostname || ing?.ip || null;
  } catch (_) { return null; }
}

app.get("/api/status", async (_req, res) => {
  try {
    const ddb = await getDocumentDB();
    const primary = ddb.spec?.clusterReplication?.primary || null;
    const replicas = ddb.spec?.clusterReplication?.replicas || [];
    const crossCloudNetworkingStrategy =
      ddb.spec?.clusterReplication?.crossCloudNetworkingStrategy ||
      ddb.spec?.crossCloudNetworkingStrategy || null;

    const clusters = await Promise.all(MEMBER_CONTEXTS.map(async (ctx) => {
      const [c, lbHost] = await Promise.all([
        findCNPGCluster(ctx),
        getServiceLBHost(ctx),
      ]);
      const phase = c?.status?.phase || null;
      const phaseReason = c?.status?.phaseReason || null;
      const ready = c?.status?.readyInstances ?? null;
      const instances = c?.status?.instances ?? null;
      const healthy = !!(phase && /healthy/i.test(phase) && ready != null && instances != null && ready === instances);
      const isPrimary = ctx === primary;
      return {
        context: ctx,
        cnpgName: c?.metadata?.name || null,
        cluster: c?.metadata?.name || null,
        currentPrimary: c?.status?.currentPrimary || null,
        primaryPod: c?.status?.currentPrimary || null,
        targetPrimary: c?.status?.targetPrimary || null,
        readyInstances: ready,
        instances,
        phase,
        phaseReason: phaseReason || (healthy ? null : phase),
        healthy,
        role: isPrimary ? "PRIMARY" : "REPLICA",
        replicaSource: c?.spec?.replica?.source || null,
        promotionToken: !!c?.spec?.replica?.promotionToken,
        inRecovery: c?.status?.currentPrimary == null,
        lbHost,
        replication: [],
      };
    }));

    // Cross-cloud replication health: gates the failover button so users
    // can't trigger another promotion before the previous one has fully
    // settled (the preview operator's failover is not robust against
    // rapid back-to-back promotions and produces split-brain divergence).
    const replicationHealthy = await checkReplicationHealthy(clusters);

    // Write probe: actually attempt a tiny upsert against the current
    // primary's MongoDB-compatible gateway. This is the ground truth for
    // "is this cluster writeable RIGHT NOW" — replicationHealthy can briefly
    // return ok=true when CNPG is mid-promotion and writes still fail.
    const writeProbe = await checkWriteProbe(primary);

    res.json({
      ok: true,
      ts: new Date().toISOString(),
      namespace: NAMESPACE,
      resource: RESOURCE,
      hubContext: HUB_CONTEXT,
      primary,
      replicas,
      crossCloudNetworkingStrategy,
      clusters,
      members: clusters,
      replicationHealthy,
      writeProbe,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

// Returns { ok: true, reason?: string, lagBytes?: number } describing
// whether cross-cloud replication is healthy enough to allow another
// failover. We require:
//   * Both clusters in "healthy" CNPG phase (ready=instances)
//   * No stale promotionToken on either side
//   * The replica's pg_stat_wal_receiver shows status="streaming"
//   * No timeline-mismatch FATALs in the last minute
//
// The pg_stat_wal_receiver probe shells into a pod via kubectl exec which
// can take 5-15s, so we cache the result for 10s. Auto-refresh in the UI
// runs every 5s and we don't need real-time accuracy here.
let _replHealthCache = { value: null, expiresAt: 0, key: null };
const REPL_HEALTH_TTL_MS = 10_000;

async function checkReplicationHealthy(clusters) {
  try {
    const primary = clusters.find((c) => c.role === "PRIMARY");
    const replica = clusters.find((c) => c.role === "REPLICA");
    if (!primary || !replica) return { ok: false, reason: "missing primary or replica cluster" };
    if (!primary.healthy) return { ok: false, reason: `primary ${primary.context} is ${primary.phase}` };
    if (!replica.healthy) return { ok: false, reason: `replica ${replica.context} is ${replica.phase}` };
    if (primary.promotionToken) return { ok: false, reason: `primary ${primary.context} still has stale promotionToken` };
    if (replica.promotionToken) return { ok: false, reason: `replica ${replica.context} still has stale promotionToken` };
    if (!primary.currentPrimary) return { ok: false, reason: "primary has no currentPrimary pod yet" };

    const podName = `${replica.cnpgName}-1`;
    const out = await kubectl([
      "--context", replica.context, "-n", NAMESPACE,
      "exec", podName, "-c", "postgres", "--",
      "psql", "-U", "postgres", "-tA", "-F", "|", "-c",
      "select status, sender_host, sender_port, latest_end_time from pg_stat_wal_receiver",
    ], { timeoutMs: 8000 });
    if (out.code !== 0) {
      return { ok: false, reason: `replica WAL receiver query failed: ${(out.stderr || "").trim().slice(0, 120)}` };
    }
    const line = (out.stdout || "").trim().split("\n").find((l) => l.includes("|"));
    if (!line) {
      return { ok: false, reason: "replica WAL receiver is not running (no row in pg_stat_wal_receiver)" };
    }
    const [status] = line.split("|");
    if (status !== "streaming") {
      return { ok: false, reason: `replica WAL receiver status="${status}" (expected "streaming")` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, reason: `health probe error: ${err.message || err}` };
  }
}

// Write probe: idempotent upsert against the primary's MongoDB-compatible
// gateway. Ground truth for "writes will succeed RIGHT NOW". Cached for 3s
// so /api/status (5s poll) stays cheap. The probe doc has a fixed _id so
// repeated probes do not grow the collection.
const PROBE_COLL = "_writeprobe";
const PROBE_ID = "monitor-app-probe";
let _writeProbeCache = { value: null, expiresAt: 0, key: null };
const WRITE_PROBE_TTL_MS = 3_000;
const WRITE_PROBE_TIMEOUT_MS = 4_000;

async function checkWriteProbe(primaryCtx) {
  const now = Date.now();
  const key = primaryCtx || "";
  if (_writeProbeCache.key === key && _writeProbeCache.expiresAt > now) {
    return _writeProbeCache.value;
  }
  let value;
  try {
    if (!primaryCtx) {
      value = { ok: false, reason: "no primary context", checkedAt: now };
    } else {
      const db = await Promise.race([
        getMongoDb(primaryCtx),
        new Promise((_, rej) => setTimeout(() => rej(new Error("mongo connect timeout")), WRITE_PROBE_TIMEOUT_MS)),
      ]);
      const ts = new Date();
      const writePromise = db.collection(PROBE_COLL).updateOne(
        { _id: PROBE_ID },
        { $set: { ts, ctx: primaryCtx } },
        { upsert: true },
      );
      const r = await Promise.race([
        writePromise,
        new Promise((_, rej) => setTimeout(() => rej(new Error("write timeout")), WRITE_PROBE_TIMEOUT_MS)),
      ]);
      value = {
        ok: true,
        primary: primaryCtx,
        latencyMs: Date.now() - now,
        checkedAt: now,
        upsertedId: r.upsertedId ? String(r.upsertedId) : null,
      };
    }
  } catch (err) {
    value = {
      ok: false,
      primary: primaryCtx,
      reason: String(err.message || err).slice(0, 200),
      latencyMs: Date.now() - now,
      checkedAt: now,
    };
  }
  _writeProbeCache = { value, expiresAt: now + WRITE_PROBE_TTL_MS, key };
  return value;
}

// Reconciles the new primary CNPG cluster after a failover:
//   1. Removes any stale promotionToken left by the operator.
//   2. Forces synchronous-commit settings to a fast-write profile
//      (preferred, ANY 1, no cross-cloud peer in standbyNamesPre).
// The DocumentDB operator regenerates these on every promotion, so we
// re-apply our overrides here. Returns nothing — best-effort.
async function reconcileNewPrimary(ctx) {
  const c = await findCNPGCluster(ctx);
  if (!c) return;
  const cnpgName = c.metadata.name;
  const hasToken = !!c?.spec?.replica?.promotionToken;
  if (hasToken) {
    const r = await kubectl([
      "--context", ctx, "-n", NAMESPACE,
      "patch", "cluster.postgresql.cnpg.io", cnpgName,
      "--type=json",
      `-p=[{"op":"remove","path":"/spec/replica/promotionToken"}]`,
    ]);
    console.log(`[reconcile:${ctx}] cleared stale promotionToken on ${cnpgName} (code=${r.code})`);
  }
  const fastSync = JSON.stringify([
    { op: "replace", path: "/spec/postgresql/synchronous/dataDurability", value: "preferred" },
    { op: "replace", path: "/spec/postgresql/synchronous/standbyNamesPre", value: [] },
    { op: "replace", path: "/spec/postgresql/synchronous/number", value: 1 },
  ]);
  const r2 = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "patch", "cluster.postgresql.cnpg.io", cnpgName,
    "--type=json", `-p=${fastSync}`,
  ]);
  console.log(`[reconcile:${ctx}] forced fast-write sync on ${cnpgName} (code=${r2.code})`);
}

app.post("/api/promote", async (req, res) => {
  const ctx = String(req.body?.context || req.body?.target || "");
  if (!MEMBER_CONTEXTS.includes(ctx)) {
    return res.status(400).json({ ok: false, error: `context must be one of ${MEMBER_CONTEXTS.join(", ")}` });
  }
  // Gate: refuse to promote if cross-cloud replication isn't healthy. Rapid
  // back-to-back failovers on the preview operator cause WAL-timeline
  // divergence that requires a full base-backup rebuild to fix.
  // Caller can pass force=true (e.g. operator override) to bypass.
  if (!req.body?.force) {
    try {
      const ddb = await getDocumentDB();
      const primary = ddb.spec?.clusterReplication?.primary || null;
      if (ctx === primary) {
        return res.status(400).json({ ok: false, error: `${ctx} is already the primary` });
      }
      const clusters = await Promise.all(MEMBER_CONTEXTS.map(async (c) => {
        const cnpg = await findCNPGCluster(c);
        return {
          context: c,
          cnpgName: cnpg?.metadata?.name || null,
          phase: cnpg?.status?.phase || null,
          healthy: !!(cnpg?.status?.phase && /healthy/i.test(cnpg.status.phase)
            && cnpg.status.readyInstances === cnpg.status.instances),
          role: c === primary ? "PRIMARY" : "REPLICA",
          currentPrimary: cnpg?.status?.currentPrimary || null,
          promotionToken: !!cnpg?.spec?.replica?.promotionToken,
        };
      }));
      const health = await checkReplicationHealthy(clusters);
      if (!health.ok) {
        return res.status(409).json({
          ok: false,
          error: `Replication is not healthy — refusing to promote. ${health.reason}`,
          replicationHealthy: false,
          reason: health.reason,
          hint: "Wait for replica to fully catch up, or POST /api/rebuild-replica { context } to force a fresh base-backup.",
        });
      }
    } catch (err) {
      return res.status(500).json({ ok: false, error: `failover gate check failed: ${err.message || err}` });
    }
  }
  const patch = JSON.stringify({ spec: { clusterReplication: { primary: ctx } } });
  const out = await kubectl([
    "--context", HUB_CONTEXT, "-n", NAMESPACE,
    "patch", "documentdb", RESOURCE, "--type=merge", "-p", patch,
  ]);
  invalidatePrimaryCtxCache();
  if (out.code === 0) {
    // Background: reconcile + warm + heal-stale-token. The DocumentDB
    // operator's cross-cloud promote handshake is unreliable on the preview
    // operator (see issue documentdb/documentdb-kubernetes-operator#375): it
    // races against itself and frequently leaves the new primary in
    // "unrecoverable" with phaseReason "Promotion token content is not
    // correct for current instance" because the token it stamped no longer
    // matches the cluster's actual WAL position.
    //
    // We work around that by polling the new primary's CNPG state for up
    // to ~3 minutes and, if we see the stale-token symptom, automatically
    // running the same recovery the "Force-promote (local token)" button
    // does: read this cluster's local promotion-token ConfigMap and stamp
    // it onto spec.replica.promotionToken + replica.primary=self. CNPG
    // then promotes pod-1 in place against its actual timeline.
    (async () => {
      try {
        await new Promise((r) => setTimeout(r, 6000));
        for (let i = 0; i < 4; i++) {
          await reconcileNewPrimary(ctx).catch((e) => console.warn(`[reconcile:${ctx}] attempt ${i+1} failed: ${e.message || e}`));
          await new Promise((r) => setTimeout(r, 4000));
        }
        await healStaleTokenIfNeeded(ctx);
        // Proactive cleanup per research: even on a "clean" promote the
        // operator leaves spec.replica.promotionToken set. Each subsequent
        // reconcile re-validates it against an advancing pg_controldata, so
        // it WILL go stale within minutes and trip #375 on the next cycle.
        // Remove it now while we're healthy so the cluster stays stable.
        await removeLingeringPromotionToken(ctx).catch((e) =>
          console.warn(`[post-heal:${ctx}] token cleanup failed: ${e.message || e}`));
        await getMongoDb(ctx);
        await refreshListingsCache(ctx);
        console.log(`[warm] re-primed mongo + listings cache for new primary ${ctx}`);
      } catch (err) {
        console.warn(`[warm] post-promote warm failed for ${ctx}: ${err.message || err}`);
      }
    })();
  }
  res.json({ ok: out.code === 0, stdout: out.stdout, stderr: out.stderr });
});

// Build a CNPG-compatible promotionToken JSON directly from the cluster's
// own pg_control_checkpoint() / pg_control_system() output. This is the
// reliable path for the post-rebuild case where the operator's sidecar CM
// (`<cluster>-promotion-token`) is missing or stale — the source of truth
// is always the live PostgreSQL control file. Returns the base64-encoded
// token suitable for spec.replica.promotionToken, or null on failure.
async function buildPromotionTokenFromPgControl(ctx, cnpgName) {
  const sql =
    "SELECT json_build_object(" +
    "'tl',timeline_id," +
    "'wal',redo_wal_file," +
    "'lsn',redo_lsn," +
    "'sid',system_identifier::text," +
    "'cptime',to_char(checkpoint_time AT TIME ZONE 'UTC','FMDy Mon DD HH24:MI:SS YYYY')" +
    ") FROM pg_control_checkpoint(),pg_control_system();";
  const r = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "exec", `${cnpgName}-1`, "-c", "postgres", "--",
    "psql", "-U", "postgres", "-tAc", sql,
  ]);
  if (r.code !== 0 || !r.stdout?.trim()) return null;
  let j;
  try { j = JSON.parse(r.stdout.trim()); } catch { return null; }
  // CNPG/operator timeOfLatestCheckpoint format is asctime-style with a
  // space-padded day-of-month (e.g. "Sat May  9 17:17:45 2026").
  const parts = String(j.cptime).split(" ").filter(Boolean);
  if (parts.length < 4) return null;
  const day = parseInt(parts[2], 10);
  const dayPad = day < 10 ? ` ${day}` : `${day}`;
  const cptime = `${parts[0]} ${parts[1]} ${dayPad} ${parts.slice(3).join(" ")}`;
  const tokenObj = {
    latestCheckpointTimelineID: String(j.tl),
    redoWalFile: String(j.wal),
    databaseSystemIdentifier: String(j.sid),
    latestCheckpointREDOLocation: String(j.lsn),
    timeOfLatestCheckpoint: cptime,
    operatorVersion: "1.28.0",
  };
  return Buffer.from(JSON.stringify(tokenObj), "utf8").toString("base64");
}

// Workaround for documentdb/documentdb-kubernetes-operator#375: after a
// promote the operator may leave the new primary stuck in "unrecoverable"
// with a stale promotionToken. Poll for that state for ~3 minutes and, if
// detected, repeatedly stamp a freshly-built promotion token (sourced from
// the cluster's own pg_control_checkpoint() — NOT the sidecar CM, which
// can be stale or absent right after a rebuild) onto spec.replica until
// CNPG accepts it and the cluster transitions to healthy.
async function removeLingeringPromotionToken(ctx) {
  const c = await findCNPGCluster(ctx).catch(() => null);
  if (!c?.metadata?.name) return;
  if (!c?.spec?.replica?.promotionToken) {
    console.log(`[post-heal:${ctx}] no lingering promotionToken on ${c.metadata.name}`);
    return;
  }
  const r = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "patch", "cluster.postgresql.cnpg.io", c.metadata.name,
    "--type=json",
    `-p=[{"op":"remove","path":"/spec/replica/promotionToken"}]`,
  ]);
  if (r.code === 0) {
    console.log(`[post-heal:${ctx}] removed lingering promotionToken from ${c.metadata.name}`);
  } else {
    console.warn(`[post-heal:${ctx}] token remove failed: ${r.stderr || r.stdout}`);
  }
}

async function healStaleTokenIfNeeded(ctx) {
  const deadline = Date.now() + 6 * 60 * 1000;
  let cnpgName = null;
  let healed = false;
  let cycle = 0;
  let healthyHits = 0; // require sustained healthy + writes work before exit
  console.log(`[heal:${ctx}] starting (window=6min)`);
  while (Date.now() < deadline) {
    cycle++;
    const c = await findCNPGCluster(ctx).catch(() => null);
    if (!c?.metadata?.name) {
      console.log(`[heal:${ctx}] cycle ${cycle}: no CNPG cluster yet, retrying`);
      await new Promise((r) => setTimeout(r, 5000));
      continue;
    }
    cnpgName = c.metadata.name;
    const phase = c.status?.phase || "";
    const reason = c.status?.phaseReason || "";
    const isHealthy = /healthy/i.test(phase) && c.status?.readyInstances === c.status?.instances;
    if (isHealthy) {
      // The operator may stamp a bad promotionToken AFTER we first see
      // "healthy" — exiting early lets that bug slip through. Require writes
      // to actually succeed via the write probe before we declare done.
      const probe = await checkWriteProbe(ctx).catch(() => ({ ok: false, reason: "probe error" }));
      healthyHits = probe.ok ? healthyHits + 1 : 0;
      console.log(`[heal:${ctx}] cycle ${cycle}: healthy phase, probe.ok=${probe.ok} (${probe.reason || `${probe.latencyMs}ms`}) hits=${healthyHits}`);
      if (healthyHits >= 2) {
        if (healed) console.log(`[heal:${ctx}] cycle ${cycle}: cluster healthy + writes confirmed after token heal — done`);
        else console.log(`[heal:${ctx}] cycle ${cycle}: cluster healthy + writes confirmed — exit`);
        return;
      }
      await new Promise((r) => setTimeout(r, 8000));
      continue;
    }
    console.log(`[heal:${ctx}] cycle ${cycle}: phase="${phase}" reason="${reason}" ready=${c.status?.readyInstances}/${c.status?.instances}`);
    healthyHits = 0;
    if (/unrecoverable/i.test(phase) && /promotion token/i.test(reason)) {
      // PER RESEARCH (.scratch/research-issue-375.md): the actual bug is that
      // the operator never clears spec.replica.promotionToken after a
      // successful promote. Each reconcile re-validates the token against
      // pg_controldata which has advanced past it, eventually returning the
      // non-retryable TokenVerificationError -> phase=Unrecoverable.
      //
      // The supported workaround (per issue #375 itself) is to REMOVE the
      // token, not rebuild it. CNPG then stops re-validating and the cluster
      // re-converges. Building a replacement token from pg_control is a red
      // herring — even a perfectly-correct token will fall stale within
      // seconds because the live primary keeps advancing the WAL.
      try {
        const r = await kubectl([
          "--context", ctx, "-n", NAMESPACE,
          "patch", "cluster.postgresql.cnpg.io", cnpgName,
          "--type=json",
          `-p=[{"op":"remove","path":"/spec/replica/promotionToken"}]`,
        ]);
        if (r.code === 0) {
          healed = true;
          console.log(`[heal:${ctx}] cycle ${cycle}: removed stale promotionToken from ${cnpgName} (issue #375 workaround)`);
        } else if (/not found/i.test(r.stderr || "")) {
          // Token already absent — nothing to remove. Cluster will converge on its own.
          console.log(`[heal:${ctx}] cycle ${cycle}: no promotionToken present, waiting for cluster to converge`);
        } else {
          console.warn(`[heal:${ctx}] cycle ${cycle}: token-remove patch failed: ${r.stderr || r.stdout}`);
        }
      } catch (err) {
        console.warn(`[heal:${ctx}] cycle ${cycle}: error: ${err.message || err}`);
      }
    }
    await new Promise((r) => setTimeout(r, 10000));
  }
  console.warn(`[heal:${ctx}] gave up waiting for cluster to heal after 6 minutes`);
}

async function clearStaleTokenHandler(req, res) {
  const ctx = String(req.body?.context || "");
  if (!MEMBER_CONTEXTS.includes(ctx)) return res.status(400).json({ ok: false, error: "bad context" });
  const c = await findCNPGCluster(ctx);
  if (!c) return res.status(404).json({ ok: false, error: "no cnpg cluster found" });
  const patched = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "patch", "cluster.postgresql.cnpg.io", c.metadata.name,
    "--type=json",
    `-p=[{"op":"remove","path":"/spec/replica/promotionToken"}]`,
  ]);
  res.json({ ok: patched.code === 0, name: c.metadata.name, stdout: patched.stdout, stderr: patched.stderr });
}
app.post("/api/clear-token", clearStaleTokenHandler);
app.post("/api/clear-stale-token", clearStaleTokenHandler);

// Force-promote a CNPG cluster using its OWN current promotion-token. This is
// the recovery path for the failure mode where a failover left this side
// "unrecoverable" with phaseReason "Promotion token content is not correct
// for current instance" — i.e. the operator stamped a stale cross-cloud token
// onto spec.replica.promotionToken that references a WAL position the local
// data is no longer at (because timeline diverged).
//
// What this endpoint does:
//   1. Read the local `promotion-token` ConfigMap (the sidecar that exposes
//      this region's current checkpoint over HTTP at /index.html).
//   2. Patch spec.replica.primary = self  (so CNPG knows we are the primary).
//   3. Patch spec.replica.promotionToken = <local token>  (matches our data).
// CNPG then promotes pod-1 in place against the timeline it actually has.
//
// This is destructive at the topology level (it makes this cluster the
// primary) so it requires confirmation from the UI.
app.post("/api/force-promote-local-token", async (req, res) => {
  const ctx = String(req.body?.context || "");
  if (!MEMBER_CONTEXTS.includes(ctx)) {
    return res.status(400).json({ ok: false, error: `context must be one of ${MEMBER_CONTEXTS.join(", ")}` });
  }
  try {
    const c = await findCNPGCluster(ctx);
    if (!c?.metadata?.name) {
      return res.status(404).json({ ok: false, error: `no CNPG cluster found in ${ctx}` });
    }
    const cnpgName = c.metadata.name;

    // Build promotionToken from the cluster's LIVE pg_control_checkpoint().
    // The `promotion-token` ConfigMap (maintained by the operator's sidecar)
    // can lag behind reality after a failover round-trip — using it here is
    // the source of issue #375 recurring even after a "force-promote-local-
    // token". Reading directly from pg_control_checkpoint() guarantees the
    // token matches the data on disk.
    const localToken = await buildPromotionTokenFromPgControl(ctx, cnpgName);
    if (!localToken) {
      return res.status(500).json({
        ok: false,
        error: `could not build promotion token from pg_control_checkpoint() in ${ctx}`,
      });
    }

    // 2 + 3. Single merge patch: set this cluster as its own primary AND
    //        set the promotionToken to its local value.
    const patch = JSON.stringify({
      spec: { replica: { primary: cnpgName, promotionToken: localToken } },
    });
    const patched = await kubectl([
      "--context", ctx, "-n", NAMESPACE,
      "patch", "cluster.postgresql.cnpg.io", cnpgName,
      "--type=merge", "-p", patch,
    ]);
    if (patched.code !== 0) {
      return res.status(500).json({
        ok: false,
        error: patched.stderr || patched.stdout || "patch failed",
      });
    }

    invalidatePrimaryCtxCache();
    // Background warm — give CNPG a few seconds to promote, then prime caches
    // so the UI starts seeing reads against the new primary quickly.
    (async () => {
      try {
        await new Promise((r) => setTimeout(r, 30000));
        await getMongoDb(ctx).catch(() => {});
        await refreshListingsCache(ctx).catch(() => {});
        console.log(`[warm] post force-promote warmed caches for ${ctx}`);
      } catch (err) {
        console.warn(`[warm] force-promote warm failed for ${ctx}: ${err.message || err}`);
      }
    })();

    res.json({
      ok: true,
      cluster: cnpgName,
      tokenLength: localToken.length,
      message: `Patched ${cnpgName}: replica.primary=self + replica.promotionToken=<local>. CNPG should promote pod-1 in place within ~30s. Watch /api/status.`,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

// Rebuild a replica cluster from scratch by deleting its CNPG Cluster
// resource. The DocumentDB hub operator reconciles within a few seconds and
// re-creates the cluster, which triggers a fresh pg_basebackup from the
// current primary via the replica's externalCluster source.
//
// This is the recovery path for WAL-timeline divergence (the replica's
// pg_stat_wal_receiver shows FATAL "requested starting point ... is not in
// this server's history") that the preview operator does not auto-resolve.
// Auto-recovery watcher for the post-rebuild cert mismatch bug in the
// DocumentDB operator (see .scratch/findings/rebuild-cert-mismatch.md).
//
// Symptom: after a rebuild, the new CNPG Cluster regenerates -ca, -server,
// and -replication secrets, but the CA stored in -ca occasionally does not
// match the issuing CA of the cert in -server. The operator logs:
//   `x509: certificate signed by unknown authority`
// and the cluster phase sticks at:
//   "Instance Status Extraction Error: HTTP communication issue"
//
// We poll the cluster phase for ~6 minutes. If it stays stuck in the
// extraction-error state for >60s AND the operator log contains x509
// errors, we delete the three cert secrets, restart the operator
// deployment so it regenerates them atomically, and delete the postgres
// pod so it picks up the fresh cert. Then we exit. Idempotent + safe.
//
// Only one watcher per context runs at a time.
const _rebuildWatchers = new Map(); // ctx -> Promise

function startRebuildWatcher(ctx, cnpgClusterName) {
  if (_rebuildWatchers.has(ctx)) {
    console.log(`[rebuild-watch:${ctx}] watcher already running; skipping`);
    return;
  }
  const p = (async () => {
    console.log(`[rebuild-watch:${ctx}] started for cluster=${cnpgClusterName}`);
    const deadline = Date.now() + 6 * 60_000;
    let stuckSince = 0;
    let fixApplied = false;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 15_000));
      // 1. read current cluster name + phase
      let cl;
      try { cl = await findCNPGCluster(ctx); } catch (_) { cl = null; }
      const name = cl?.metadata?.name || cnpgClusterName;
      const phase = cl?.status?.phase || "(unknown)";
      console.log(`[rebuild-watch:${ctx}] cluster=${name} phase="${phase}"`);
      if (/^Cluster in healthy state/i.test(phase)) {
        console.log(`[rebuild-watch:${ctx}] cluster healthy; exiting watcher`);
        break;
      }
      const isStuckCert = /Instance Status Extraction Error|HTTP communication issue/i.test(phase);
      if (!isStuckCert) { stuckSince = 0; continue; }
      if (stuckSince === 0) stuckSince = Date.now();
      const stuckMs = Date.now() - stuckSince;
      if (stuckMs < 60_000 || fixApplied) continue;
      // 2. confirm via operator log that it's the x509 bug
      const log = await kubectl(
        ["--context", ctx, "-n", "cnpg-system", "logs",
         "deploy/documentdb-operator-cloudnative-pg", "--tail=30", "--since=2m"],
        { timeoutMs: 8000 }
      );
      const sawX509 = /x509|unknown authority|verification failure/i.test((log.stdout || "") + (log.stderr || ""));
      if (!sawX509) {
        console.log(`[rebuild-watch:${ctx}] stuck but no x509 errors in operator log; leaving for manual review`);
        continue;
      }
      console.log(`[rebuild-watch:${ctx}] detected cert mismatch (x509). Applying auto-fix on cluster=${name}`);
      fixApplied = true;
      // 3. delete cert secrets
      await kubectl(
        ["--context", ctx, "-n", NAMESPACE, "delete", "secret",
         `${name}-ca`, `${name}-server`, `${name}-replication`, "--ignore-not-found"],
        { timeoutMs: 15000 }
      );
      // 4. restart operator
      await kubectl(
        ["--context", ctx, "-n", "cnpg-system", "rollout", "restart",
         "deploy/documentdb-operator-cloudnative-pg"],
        { timeoutMs: 15000 }
      );
      await kubectl(
        ["--context", ctx, "-n", "cnpg-system", "rollout", "status",
         "deploy/documentdb-operator-cloudnative-pg", "--timeout=90s"],
        { timeoutMs: 100000 }
      );
      // 5. delete pod so it picks up fresh cert
      await kubectl(
        ["--context", ctx, "-n", NAMESPACE, "delete", "pod", `${name}-1`, "--wait=false"],
        { timeoutMs: 15000 }
      );
      console.log(`[rebuild-watch:${ctx}] auto-fix applied; will keep polling for healthy state`);
      stuckSince = 0;
    }
    console.log(`[rebuild-watch:${ctx}] watcher exiting`);
  })().catch((err) => {
    console.error(`[rebuild-watch:${ctx}] error: ${err.message || err}`);
  }).finally(() => {
    _rebuildWatchers.delete(ctx);
  });
  _rebuildWatchers.set(ctx, p);
}

app.post("/api/rebuild-replica", async (req, res) => {
  const ctx = String(req.body?.context || "");
  if (!MEMBER_CONTEXTS.includes(ctx)) {
    return res.status(400).json({ ok: false, error: `context must be one of ${MEMBER_CONTEXTS.join(", ")}` });
  }
  try {
    const ddb = await getDocumentDB();
    const primary = ddb.spec?.clusterReplication?.primary || null;
    if (ctx === primary) {
      return res.status(400).json({
        ok: false,
        error: `${ctx} is the current primary — refusing to wipe it. Promote the other cluster first if you really need to rebuild this one.`,
      });
    }
    const c = await findCNPGCluster(ctx);
    if (!c?.metadata?.name) {
      return res.status(404).json({ ok: false, error: `no CNPG cluster found in ${ctx}` });
    }
    // Don't --wait; DocumentDB operator will recreate it asynchronously and
    // we want to return quickly so the UI can poll status.
    const del = await kubectl([
      "--context", ctx, "-n", NAMESPACE,
      "delete", "cluster.postgresql.cnpg.io", c.metadata.name, "--wait=false",
    ]);
    if (del.code !== 0) {
      return res.status(500).json({ ok: false, error: del.stderr || del.stdout || "delete failed" });
    }
    // Also wipe the PVCs. Without this, the operator reuses the existing
    // disks and the new "replica" boots with stale WAL on the OLD timeline,
    // which then can't catch up to the new primary's forked timeline
    // (FATAL: requested starting point ... is not in this server's history).
    // Deleting PVCs forces a true pg_basebackup from the current primary.
    kubectl([
      "--context", ctx, "-n", NAMESPACE,
      "delete", "pvc", "-l", `cnpg.io/cluster=${c.metadata.name}`,
      "--wait=false", "--ignore-not-found",
    ]).catch((err) => console.error(`[rebuild:${ctx}] PVC delete failed: ${err.message || err}`));
    res.json({
      ok: true,
      cluster: c.metadata.name,
      message: `Deleted CNPG cluster ${c.metadata.name} (and PVCs) in ${ctx}. The DocumentDB operator will re-bootstrap it from primary via pg_basebackup. Auto-healing watcher engaged for known cert-mismatch issue. Watch /api/status for progress.`,
    });
    // Fire-and-forget background watcher that auto-recovers from the
    // post-rebuild cert-mismatch bug (see findings doc).
    startRebuildWatcher(ctx, c.metadata.name);
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

// ---------- Primary-context cache ----------
let _primaryCtxCache = { value: null, expiresAt: 0 };
async function getGlobalPrimaryContext() {
  const now = Date.now();
  if (_primaryCtxCache.expiresAt > now && _primaryCtxCache.value) return _primaryCtxCache.value;
  try {
    const ddb = await getDocumentDB();
    const v = ddb.spec?.clusterReplication?.primary || null;
    _primaryCtxCache = { value: v, expiresAt: now + 300000 };
    return v;
  } catch (err) {
    if (_primaryCtxCache.value) {
      _primaryCtxCache.expiresAt = now + 30000;
      return _primaryCtxCache.value;
    }
    throw err;
  }
}
function invalidatePrimaryCtxCache() { _primaryCtxCache = { value: null, expiresAt: 0 }; }

// ---------- Mongo gateway via persistent kubectl port-forward ----------
const mongoState = new Map(); // ctx -> { client, db, port, pf, password, ready }
let nextLocalPort = 57017;

async function getGatewayPassword(ctx) {
  const sec = await kubectl([
    "--context", ctx, "-n", NAMESPACE,
    "get", "secret", CREDENTIALS_SECRET,
    "-o", "jsonpath={.data.password}",
  ]);
  if (sec.code !== 0) throw new Error(`get ${CREDENTIALS_SECRET} on ${ctx}: ${sec.stderr}`);
  return fromB64((sec.stdout || "").trim());
}

function startPortForward(ctx, localPort) {
  const args = [
    "--context", ctx, "-n", NAMESPACE,
    "port-forward", `svc/${GATEWAY_SVC}`, `${localPort}:${GATEWAY_PORT}`,
  ];
  console.log(`[pf:${ctx}] kubectl ${args.join(" ")}`);
  const pf = spawn(KUBECTL, args, { stdio: ["ignore", "pipe", "pipe"] });
  pf.stdout.on("data", (d) => process.stderr.write(`[pf:${ctx}] ${d}`));
  pf.stderr.on("data", (d) => process.stderr.write(`[pf:${ctx}] ${d}`));
  pf.on("exit", (code, sig) => {
    console.error(`[pf:${ctx}] exited code=${code} sig=${sig} — invalidating client`);
    const st = mongoState.get(ctx);
    if (st?.client) { st.client.close().catch(() => {}); }
    mongoState.delete(ctx);
  });
  return pf;
}

async function waitForPort(host, port, timeoutMs = 10_000) {
  const net = require("net");
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const ok = await new Promise((resolve) => {
      const s = net.createConnection({ host, port });
      s.once("connect", () => { s.end(); resolve(true); });
      s.once("error", () => resolve(false));
    });
    if (ok) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

async function getMongoDb(ctx) {
  if (!MEMBER_CONTEXTS.includes(ctx)) throw new Error(`unknown context ${ctx}`);
  let st = mongoState.get(ctx);
  if (st) return st.ready;
  const port = nextLocalPort++;
  st = { port };
  mongoState.set(ctx, st);
  st.ready = (async () => {
    st.password = await getGatewayPassword(ctx);
    st.pf = startPortForward(ctx, port);
    const up = await waitForPort("127.0.0.1", port, 12_000);
    if (!up) {
      try { st.pf.kill(); } catch (_) {}
      mongoState.delete(ctx);
      throw new Error(`port-forward to ${ctx}/${GATEWAY_SVC} never became ready`);
    }
    const uri = `mongodb://${encodeURIComponent(GATEWAY_USER)}:${encodeURIComponent(st.password)}@127.0.0.1:${port}/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true`;
    st.client = new MongoClient(uri, {
      serverSelectionTimeoutMS: 8_000,
      connectTimeoutMS: 8_000,
      maxPoolSize: 32,
      minPoolSize: 2,
    });
    await st.client.connect();
    st.db = st.client.db(DEMO_DB);
    console.log(`[mongo:${ctx}] connected via 127.0.0.1:${port} → ${GATEWAY_SVC}:${GATEWAY_PORT}`);
    return st.db;
  })().catch((err) => { mongoState.delete(ctx); throw err; });
  return st.ready;
}

// ---------- Loadgen-isolated Mongo pool ----------
// The load tester uses a SEPARATE MongoClient + port-forward so that bursts of
// loadgen traffic can't starve the shared pool used by the topology tab's
// write probe, replication monitor, bookings tab, etc.
const loadgenMongoState = new Map(); // ctx -> { client, db, port, pf, password, ready }

async function getLoadgenMongoDb(ctx) {
  if (!MEMBER_CONTEXTS.includes(ctx)) throw new Error(`unknown context ${ctx}`);
  let st = loadgenMongoState.get(ctx);
  if (st) return st.ready;
  const port = nextLocalPort++;
  st = { port };
  loadgenMongoState.set(ctx, st);
  st.ready = (async () => {
    st.password = await getGatewayPassword(ctx);
    const args = [
      "--context", ctx, "-n", NAMESPACE,
      "port-forward", `svc/${GATEWAY_SVC}`, `${port}:${GATEWAY_PORT}`,
    ];
    console.log(`[pf:loadgen:${ctx}] kubectl ${args.join(" ")}`);
    st.pf = spawn(KUBECTL, args, { stdio: ["ignore", "pipe", "pipe"] });
    st.pf.stdout.on("data", (d) => process.stderr.write(`[pf:loadgen:${ctx}] ${d}`));
    st.pf.stderr.on("data", (d) => process.stderr.write(`[pf:loadgen:${ctx}] ${d}`));
    st.pf.on("exit", (code, sig) => {
      console.error(`[pf:loadgen:${ctx}] exited code=${code} sig=${sig} — invalidating client`);
      const cur = loadgenMongoState.get(ctx);
      if (cur?.client) { cur.client.close().catch(() => {}); }
      loadgenMongoState.delete(ctx);
    });
    const up = await waitForPort("127.0.0.1", port, 12_000);
    if (!up) {
      try { st.pf.kill(); } catch (_) {}
      loadgenMongoState.delete(ctx);
      throw new Error(`loadgen port-forward to ${ctx}/${GATEWAY_SVC} never became ready`);
    }
    const uri = `mongodb://${encodeURIComponent(GATEWAY_USER)}:${encodeURIComponent(st.password)}@127.0.0.1:${port}/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true`;
    st.client = new MongoClient(uri, {
      serverSelectionTimeoutMS: 8_000,
      connectTimeoutMS: 8_000,
      maxPoolSize: 12,
      minPoolSize: 1,
    });
    await st.client.connect();
    st.db = st.client.db(DEMO_DB);
    console.log(`[mongo:loadgen:${ctx}] connected via 127.0.0.1:${port} → ${GATEWAY_SVC}:${GATEWAY_PORT} (pool=12)`);
    return st.db;
  })().catch((err) => { loadgenMongoState.delete(ctx); throw err; });
  return st.ready;
}

// ---------- Data replication demo: bookings on listings ----------

const MARVEL_GUESTS = [
  "Tony Stark", "Pepper Potts", "Steve Rogers", "Natasha Romanoff",
  "Bruce Banner", "Thor Odinson", "Clint Barton", "Wanda Maximoff",
  "Vision", "Sam Wilson", "Bucky Barnes", "Scott Lang", "Hope van Dyne",
  "Stephen Strange", "Wong", "Peter Parker", "MJ Watson", "Ned Leeds",
  "Carol Danvers", "Nick Fury", "Maria Hill", "T'Challa", "Shuri",
  "Okoye", "Nakia", "M'Baku", "Peter Quill", "Gamora", "Rocket",
  "Drax", "Mantis", "Nebula", "Yondu Udonta", "Loki", "Heimdall",
  "Valkyrie", "Korg", "Miek", "Hela", "Matt Murdock", "Jessica Jones",
  "Luke Cage", "Danny Rand", "Frank Castle", "Karen Page", "Foggy Nelson",
  "Kamala Khan", "Jen Walters", "Kate Bishop", "Yelena Belova",
  "Marc Spector", "Layla El-Faouly", "Riri Williams", "America Chavez",
  "Maya Lopez", "Eric Brooks", "Shang-Chi", "Katy Chen", "Xu Xialing",
];
const STATUSES = ["confirmed", "pending", "cancelled"];

function randomChoice(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function pickN(arr, n) {
  const out = []; const seen = new Set();
  while (out.length < n && seen.size < arr.length) {
    const i = Math.floor(Math.random() * arr.length);
    if (!seen.has(i)) { seen.add(i); out.push(arr[i]); }
  }
  return out;
}
function isoDate(d) { return d.toISOString().slice(0, 10); }
function makeBookingFromListing(listing, guestName, status) {
  const checkIn = new Date(Date.now() + (3 + Math.floor(Math.random() * 90)) * 86400_000);
  const nights = 1 + Math.floor(Math.random() * 7);
  const checkOut = new Date(checkIn.getTime() + nights * 86400_000);
  return {
    guest_name: guestName,
    listing_id: listing._id || listing.id,
    listing_display_name: listing.displayName || listing.name,
    city: listing.city || "",
    country: listing.country || "",
    nights,
    price_per_night: listing.price ?? null,
    total_price: listing.price != null ? listing.price * nights : null,
    check_in: isoDate(checkIn),
    check_out: isoDate(checkOut),
    status: status || randomChoice(STATUSES),
    created_at: new Date(),
  };
}

// Cached listings cache to avoid an extra cross-cloud round-trip per insert.
// We pull a batch of listings once per primary context, then sample from the
// in-memory cache. Refreshes every 5 minutes or on demand.
const _listingsCache = new Map(); // ctx -> { sample: Array, expiresAt: number, fetching: Promise }
const LISTINGS_CACHE_TTL_MS = 5 * 60_000;
const LISTINGS_CACHE_SIZE = 200;

async function refreshListingsCache(ctx) {
  const db = await getMongoDb(ctx);
  const cursor = db.collection(LISTINGS_COLL).aggregate([
    { $sample: { size: LISTINGS_CACHE_SIZE } },
    { $project: { _id: 1, id: 1, name: 1, displayName: 1, city: 1, country: 1, price: 1 } },
  ], { allowDiskUse: true });
  const sample = await cursor.toArray();
  _listingsCache.set(ctx, { sample, expiresAt: Date.now() + LISTINGS_CACHE_TTL_MS, fetching: null });
  return sample;
}

async function fetchListingsSample(ctx, count) {
  let entry = _listingsCache.get(ctx);
  const now = Date.now();
  if (!entry || entry.expiresAt <= now || entry.sample.length === 0) {
    if (entry?.fetching) {
      await entry.fetching;
    } else {
      const p = refreshListingsCache(ctx);
      _listingsCache.set(ctx, { sample: entry?.sample || [], expiresAt: entry?.expiresAt || 0, fetching: p });
      await p;
    }
    entry = _listingsCache.get(ctx);
  }
  // Random in-memory sample without replacement (or with, if count > cache size).
  const pool = entry.sample;
  if (pool.length === 0) return [];
  const out = [];
  const used = new Set();
  while (out.length < count) {
    const idx = Math.floor(Math.random() * pool.length);
    if (count <= pool.length && used.has(idx)) continue;
    used.add(idx);
    out.push(pool[idx]);
    if (out.length >= pool.length) break;
  }
  return out;
}

app.post("/api/data/seed", async (_req, res) => {
  try {
    const primaryCtx = await getGlobalPrimaryContext();
    if (!primaryCtx) return res.status(500).json({ ok: false, error: "no primary cluster" });
    const db = await getMongoDb(primaryCtx);
    const existing = await db.collection(BOOKINGS_COLL).estimatedDocumentCount();
    let seeded = 0;
    if (existing === 0) {
      const listings = await fetchListingsSample(primaryCtx, 5);
      if (listings.length === 0) {
        return res.status(409).json({ ok: false, error: `no documents in ${DEMO_DB}.${LISTINGS_COLL} — load listings first` });
      }
      const guests = pickN(MARVEL_GUESTS, listings.length);
      const docs = listings.map((l, i) => makeBookingFromListing(l, guests[i], "confirmed"));
      const r = await db.collection(BOOKINGS_COLL).insertMany(docs);
      seeded = r.insertedCount;
    }
    res.json({ ok: true, primaryContext: primaryCtx, existingRows: existing, seeded });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.post("/api/data/insert", async (req, res) => {
  try {
    const b = req.body || {};
    const count = Math.min(Math.max(parseInt(b.count, 10) || 1, 1), 50);
    const status = String(b.status || "confirmed").slice(0, 32);
    const guestName = b.guest_name && String(b.guest_name).trim().slice(0, 200);
    const primaryCtx = await getGlobalPrimaryContext();
    if (!primaryCtx) return res.status(500).json({ ok: false, error: "no primary cluster" });
    const db = await getMongoDb(primaryCtx);
    const listings = await fetchListingsSample(primaryCtx, count);
    if (listings.length === 0) {
      return res.status(409).json({ ok: false, error: `no documents in ${DEMO_DB}.${LISTINGS_COLL}` });
    }
    const guests = guestName ? Array(count).fill(guestName) : pickN(MARVEL_GUESTS, count);
    const docs = listings.map((l, i) => makeBookingFromListing(l, guests[i % guests.length], status));
    const r = await db.collection(BOOKINGS_COLL).insertMany(docs);
    const inserted = Object.values(r.insertedIds).map((id, i) => ({
      id: String(id),
      createdMs: docs[i].created_at.getTime(),
      guest_name: docs[i].guest_name,
      listing_display_name: docs[i].listing_display_name,
      city: docs[i].city,
    }));
    res.json({
      ok: true,
      primaryContext: primaryCtx,
      count: inserted.length,
      ids: inserted.map((r) => r.id),
      inserted,
      serverReceivedMs: Date.now(),
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.get("/api/data/list", async (req, res) => {
  try {
    const ctx = String(req.query.context || "");
    if (!MEMBER_CONTEXTS.includes(ctx)) {
      return res.status(400).json({ ok: false, error: `context must be one of ${MEMBER_CONTEXTS.join(", ")}` });
    }
    const limit = Math.min(parseInt(req.query.limit, 10) || 20, 200);
    const db = await getMongoDb(ctx);
    let docs;
    try {
      docs = await db.collection(BOOKINGS_COLL)
        .find({}, { projection: { guest_name: 1, listing_display_name: 1, city: 1, country: 1, check_in: 1, check_out: 1, status: 1, total_price: 1, created_at: 1 } })
        .sort({ created_at: -1, _id: -1 })
        .limit(limit)
        .toArray();
    } catch (err) {
      // Collection may not exist yet on a freshly-promoted replica
      if (/ns not found|NamespaceNotFound/i.test(String(err.message))) {
        return res.json({ ok: true, context: ctx, rows: [], notSeeded: true });
      }
      throw err;
    }
    const observedMs = Date.now();
    const rows = docs.map((d) => ({
      id: String(d._id),
      guest_name: d.guest_name,
      listing_display_name: d.listing_display_name || "",
      city: d.city || "",
      country: d.country || "",
      check_in: d.check_in,
      check_out: d.check_out,
      status: d.status,
      total_price: d.total_price ?? null,
      createdMs: d.created_at instanceof Date ? d.created_at.getTime() : Date.parse(d.created_at) || null,
    }));
    res.json({ ok: true, context: ctx, observedMs, rows });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.post("/api/data/wait-for-replication", async (req, res) => {
  try {
    const ctx = String(req.body?.context || "");
    if (!MEMBER_CONTEXTS.includes(ctx)) {
      return res.status(400).json({ ok: false, error: `context must be one of ${MEMBER_CONTEXTS.join(", ")}` });
    }
    const idsRaw = Array.isArray(req.body?.ids) ? req.body.ids : [];
    if (idsRaw.length === 0) return res.status(400).json({ ok: false, error: "ids array required" });
    const { ObjectId } = require("mongodb");
    const ids = idsRaw.map((s) => { try { return new ObjectId(String(s)); } catch { return null; } }).filter(Boolean);
    if (ids.length === 0) return res.status(400).json({ ok: false, error: "ids array contained no valid ObjectIds" });
    const timeoutSec = Math.min(Math.max(parseInt(req.body?.timeoutSec, 10) || 8, 1), 30);

    const db = await getMongoDb(ctx);
    const expected = ids.length;
    const deadline = Date.now() + timeoutSec * 1000;
    const t0 = Date.now();
    let observed = 0;
    while (Date.now() < deadline) {
      try {
        observed = await db.collection(BOOKINGS_COLL).countDocuments({ _id: { $in: ids } });
      } catch (err) {
        if (!/ns not found|NamespaceNotFound/i.test(String(err.message))) throw err;
        observed = 0;
      }
      if (observed >= expected) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    const lagMs = Date.now() - t0;
    res.json({
      ok: true,
      context: ctx,
      lagMs,
      observedCount: observed,
      expected,
      timedOut: observed < expected,
      wallMs: lagMs,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.post("/api/data/delete", async (req, res) => {
  try {
    const idsRaw = Array.isArray(req.body?.ids) ? req.body.ids : [];
    if (idsRaw.length === 0) return res.status(400).json({ ok: false, error: "ids array required" });
    const { ObjectId } = require("mongodb");
    const ids = idsRaw.map((s) => { try { return new ObjectId(String(s)); } catch { return null; } }).filter(Boolean);
    if (ids.length === 0) return res.status(400).json({ ok: false, error: "ids contained no valid ObjectIds" });
    const primaryCtx = await getGlobalPrimaryContext();
    const db = await getMongoDb(primaryCtx);
    const r = await db.collection(BOOKINGS_COLL).deleteMany({ _id: { $in: ids } });
    res.json({ ok: true, deleted: r.deletedCount, requested: ids.length });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.post("/api/data/reset", async (_req, res) => {
  try {
    const primaryCtx = await getGlobalPrimaryContext();
    const db = await getMongoDb(primaryCtx);
    try {
      await db.collection(BOOKINGS_COLL).drop();
    } catch (err) {
      if (!/ns not found|NamespaceNotFound/i.test(String(err.message))) throw err;
    }
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

// ---------- Load generator ----------

const loadgen = new LoadGen({
  getDbForPrimary: async () => {
    const ctx = await getGlobalPrimaryContext();
    if (!ctx) return null;
    return getLoadgenMongoDb(ctx);
  },
  log: (msg) => console.log(msg),
});

app.get("/api/loadgen/status", (_req, res) => {
  res.json({ ok: true, status: loadgen.status(), max_rps: MAX_RPS });
});

app.post("/api/loadgen/start", async (req, res) => {
  try {
    const rps = Number(req.body?.rps);
    const mix = req.body?.mix;
    const status = await loadgen.start({ rps, mix });
    res.json({ ok: true, status });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.post("/api/loadgen/stop", (_req, res) => {
  res.json({ ok: true, status: loadgen.stop() });
});

app.post("/api/loadgen/reset-collection", async (_req, res) => {
  try {
    const primaryCtx = await getGlobalPrimaryContext();
    if (!primaryCtx) return res.status(503).json({ ok: false, error: "no primary" });
    const db = await getMongoDb(primaryCtx);
    try {
      await db.collection("loadgen_bookings").drop();
    } catch (err) {
      if (!/ns not found|NamespaceNotFound/i.test(String(err.message))) throw err;
    }
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

// ---------- Vector search demo (local Docker only) ----------

const LOCAL_MONGODB_URI = process.env.LOCAL_MONGODB_URI ||
  "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true";
const EMBEDDING_DIM = 1536;
const EMBEDDING_MODEL = process.env.AZURE_OPENAI_EMBEDDING_MODEL || "text-embedding-3-small";
const VECTOR_INDEX_NAME = "vectorSearchIndex";

let _localClient = null;
async function getLocalDb() {
  if (_localClient) return _localClient.db(DEMO_DB);
  const c = new MongoClient(LOCAL_MONGODB_URI, {
    serverSelectionTimeoutMS: 5_000, connectTimeoutMS: 5_000, maxPoolSize: 4,
  });
  await c.connect();
  _localClient = c;
  console.log(`[vector-search] connected to local Mongo: ${LOCAL_MONGODB_URI.replace(/:[^:@]+@/, ":***@")}`);
  return c.db(DEMO_DB);
}

async function embedQuery(text) {
  const azEndpoint = process.env.AZURE_OPENAI_ENDPOINT;
  const azKey = process.env.AZURE_OPENAI_API_KEY;
  const azDep = process.env.AZURE_OPENAI_EMBEDDING_DEPLOYMENT || EMBEDDING_MODEL;
  const azVer = process.env.AZURE_OPENAI_API_VERSION || "2024-10-21";
  const oaiKey = process.env.OPENAI_API_KEY;

  let url, headers;
  if (azEndpoint && azKey) {
    const base = azEndpoint.endsWith("/") ? azEndpoint.slice(0, -1) : azEndpoint;
    url = `${base}/openai/deployments/${encodeURIComponent(azDep)}/embeddings?api-version=${encodeURIComponent(azVer)}`;
    headers = { "Content-Type": "application/json", "api-key": azKey };
  } else if (oaiKey) {
    url = "https://api.openai.com/v1/embeddings";
    headers = { "Content-Type": "application/json", "Authorization": `Bearer ${oaiKey}` };
  } else {
    throw new Error("No embedding credentials configured. Set AZURE_OPENAI_* or OPENAI_API_KEY in .env");
  }

  const body = { input: text, model: EMBEDDING_MODEL };
  const r = await fetch(url, { method: "POST", headers, body: JSON.stringify(body) });
  if (!r.ok) {
    const txt = await r.text().catch(() => "");
    throw new Error(`embedding request failed: HTTP ${r.status} ${txt.slice(0, 300)}`);
  }
  const j = await r.json();
  const v = j.data?.[0]?.embedding;
  if (!Array.isArray(v) || v.length !== EMBEDDING_DIM) {
    throw new Error(`bad embedding response (got dim=${v?.length})`);
  }
  return v;
}

app.post("/api/vector-search", async (req, res) => {
  try {
    const q = String(req.body?.q || "").trim();
    if (!q) return res.status(400).json({ ok: false, error: "q (text) is required" });
    const k = Math.min(Math.max(parseInt(req.body?.k, 10) || 5, 1), 20);

    const t0 = Date.now();
    const vector = await embedQuery(q);
    const tEmbed = Date.now() - t0;

    const db = await getLocalDb();
    const t1 = Date.now();
    const cursor = db.collection(LISTINGS_COLL).aggregate([
      {
        $search: {
          cosmosSearch: {
            vector,
            path: "descriptionVector",
            k,
          },
          returnStoredSource: true,
        },
      },
      {
        $project: {
          _id: 0,
          score: { $meta: "searchScore" },
          displayName: 1,
          city: 1,
          country: 1,
          price: 1,
          property_type: 1,
          bedrooms: 1,
          tags: 1,
          neighborhood_summary: 1,
        },
      },
    ]);
    const rows = await cursor.toArray();
    const tSearch = Date.now() - t1;

    res.json({
      ok: true,
      q,
      k,
      embedDim: vector.length,
      embedModel: EMBEDDING_MODEL,
      embedMs: tEmbed,
      searchMs: tSearch,
      totalMs: Date.now() - t0,
      indexName: VECTOR_INDEX_NAME,
      rows,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: String(err.message || err) });
  }
});

app.listen(PORT, () => {
  console.log(`DocumentDB monitor listening on http://localhost:${PORT}`);
  console.log(`Hub: ${HUB_CONTEXT}, members: ${MEMBER_CONTEXTS.join(", ")}, ns: ${NAMESPACE}, resource: ${RESOURCE}`);
  console.log(`Data demo target: db=${DEMO_DB}, listings=${LISTINGS_COLL}, bookings=${BOOKINGS_COLL}, gateway svc=${GATEWAY_SVC}:${GATEWAY_PORT}`);
  const haveAz = !!(process.env.AZURE_OPENAI_ENDPOINT && process.env.AZURE_OPENAI_API_KEY);
  const haveOai = !!process.env.OPENAI_API_KEY;
  console.log(`Vector search: local Mongo=${LOCAL_MONGODB_URI.replace(/:[^:@]+@/, ":***@")}; embeddings via ${haveAz ? "Azure OpenAI" : haveOai ? "OpenAI" : "(no creds — set AZURE_OPENAI_* or OPENAI_API_KEY in .env)"}`);
  getGlobalPrimaryContext()
    .then(async (ctx) => {
      console.log(`[warm] primary context cached: ${ctx}`);
      if (!ctx) return;
      // Pre-warm the Mongo gateway connection AND the listings sample cache
      // for the current primary. This eliminates the multi-second first-write
      // penalty after server start or a failover.
      try {
        await getMongoDb(ctx);
        await refreshListingsCache(ctx);
        console.log(`[warm] mongo + listings cache primed for ${ctx}`);
      } catch (err) {
        console.warn(`[warm] mongo/listings warm failed for ${ctx}: ${err.message || err}`);
      }
      // Also pre-warm replica Mongo gateways in parallel so the Bookings tab
      // does not pay a 5-10s cold start when the user first switches to it.
      const replicas = MEMBER_CONTEXTS.filter((c) => c !== ctx);
      await Promise.all(replicas.map(async (rctx) => {
        try {
          await getMongoDb(rctx);
          console.log(`[warm] mongo primed for replica ${rctx}`);
        } catch (err) {
          console.warn(`[warm] mongo warm failed for replica ${rctx}: ${err.message || err}`);
        }
      }));
    })
    .catch((err) => console.warn(`[warm] primary context warm failed: ${err.message || err}`));
});
