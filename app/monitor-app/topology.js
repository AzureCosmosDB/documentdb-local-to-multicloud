"use strict";

function membersFromDocument(document, contexts) {
  const replication = document.spec?.clusterReplication;
  const names = replication?.clusterList?.map((member) => member.name) || [];
  if (!names.length || new Set(names).size !== names.length ||
      !names.includes(replication.primary)) {
    throw new Error("DocumentDB has no valid replication topology");
  }
  const missing = names.filter((name) => !contexts.includes(name));
  if (missing.length) throw new Error(`Missing member contexts: ${missing.join(", ")}`);
  return { primary: replication.primary, members: names, replicas: names.filter((name) => name !== replication.primary) };
}

function selectCNPGCluster(items, resource) {
  const owned = items.filter((cluster) => cluster.metadata?.ownerReferences?.some(
    (owner) => owner.kind === "DocumentDB" && owner.name === resource &&
      owner.apiVersion?.startsWith("documentdb.io/")));
  if (owned.length > 1) throw new Error(`Multiple CNPG shards for ${resource}; this demo supports nodeCount: 1`);
  return owned[0] || null;
}

function clusterStatus(context, cluster, primary) {
  const status = cluster?.status || {};
  return {
    context,
    cnpgName: cluster?.metadata?.name || null,
    currentPrimary: status.currentPrimary || null,
    phase: status.phase || null,
    healthy: status.phase === "Cluster in healthy state" &&
      status.readyInstances > 0 && status.readyInstances === status.instances,
    role: context === primary ? "PRIMARY" : "REPLICA",
    promotionToken: !!cluster?.spec?.replica?.promotionToken,
    replicaSource: cluster?.spec?.replica?.source || null,
    replicaPrimary: cluster?.spec?.replica?.primary || null,
  };
}

async function checkReplication(clusters, probe) {
  const primary = clusters.find((cluster) => cluster.role === "PRIMARY");
  const replicas = clusters.filter((cluster) => cluster.role === "REPLICA");
  if (!primary || !replicas.length) return { ok: false, reason: "missing primary or replica cluster" };
  for (const cluster of clusters) {
    if (!cluster.healthy || !cluster.currentPrimary) {
      return { ok: false, context: cluster.context, reason: `${cluster.context} is ${cluster.phase || "unavailable"}` };
    }
    if (cluster.promotionToken) return { ok: false, context: cluster.context, reason: `${cluster.context} still has a promotionToken; wait for operator reconciliation` };
    if (cluster.replicaPrimary !== primary.cnpgName) {
      return { ok: false, context: cluster.context, reason: `${cluster.context} has not converged on primary ${primary.context}` };
    }
  }
  const results = await Promise.all(replicas.map(async (replica) => {
    try {
      if (replica.replicaSource !== primary.cnpgName) throw new Error("replica source has not converged on the current primary");
      const result = await probe(replica);
      if (!result.ok) return { ...result, context: replica.context };
      return { ok: true, context: replica.context };
    } catch (error) {
      return { ok: false, context: replica.context, reason: error.message };
    }
  }));
  const failed = results.find((result) => !result.ok);
  return failed
    ? { ...failed, reason: `${failed.context}: ${failed.reason}`, members: results }
    : { ok: true, members: results };
}

function createPromotionHandler({ getTopology, checkHealth, kubectl, invalidate, namespace, resource, hubContext }) {
  let busy = false;
  return async (req, res) => {
    if (busy) return res.status(409).json({ ok: false, error: "Another topology operation is in progress" });
    if (req.body?.force) return res.status(400).json({ ok: false, error: "Forced failover is not supported by this demo; use the documented operator disaster-recovery procedure." });
    busy = true;
    try {
      const target = String(req.body?.context || req.body?.target || "");
      const { primary, members, clusters } = await getTopology();
      if (!members.includes(target) || target === primary) {
        return res.status(400).json({ ok: false, error: "Target must be a replica in the active DocumentDB clusterList" });
      }
      const health = await checkHealth(clusters);
      if (!health.ok) return res.status(409).json({ ok: false, error: `Replication is not healthy: ${health.reason}`, reason: health.reason });
      invalidate();
      const out = await kubectl([
        "documentdb", "promote", "--documentdb", resource, "--namespace", namespace,
        "--hub-context", hubContext, "--target-cluster", target, "--cluster-context", target,
        "--wait-timeout", "10m",
      ], { timeoutMs: 660_000 });
      return res.status(out.code === 0 ? 200 : 502).json({
        ok: out.code === 0, stdout: out.stdout, stderr: out.stderr,
        ...(out.code === 0 ? {} : { error: "Promotion did not complete; inspect topology before retrying." }),
      });
    } catch (error) {
      return res.status(500).json({ ok: false, error: error.message });
    } finally {
      invalidate();
      busy = false;
    }
  };
}

module.exports = { membersFromDocument, selectCNPGCluster, clusterStatus, checkReplication, createPromotionHandler };
