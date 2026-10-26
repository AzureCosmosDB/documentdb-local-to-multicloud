const { test } = require("node:test");
const assert = require("node:assert/strict");
const { membersFromDocument, selectCNPGCluster, clusterStatus, checkReplication, createPromotionHandler } = require("../topology");

const names = ["azure-documentdb", "azure-documentdb-secondary", "aws-documentdb"];
function document(primary = names[0], members = names) {
  return { spec: { clusterReplication: { primary, clusterList: members.map((name) => ({ name })) } } };
}
function clusters(primary = names[0], members = names) {
  return members.map((context) => ({
    context, role: context === primary ? "PRIMARY" : "REPLICA", cnpgName: `${context}-db`,
    currentPrimary: `${context}-db-2`, healthy: true, phase: "Cluster in healthy state",
    replicaPrimary: `${primary}-db`, replicaSource: `${primary}-db`,
  }));
}
function response() {
  return { statusCode: 200, status(code) { this.statusCode = code; return this; }, json(body) { this.body = body; return this; } };
}

test("two AKS members retain separate identities with or without EKS", () => {
  for (const members of [names.slice(0, 2), names]) {
    for (const primary of members) {
      const topology = membersFromDocument(document(primary, members), names);
      assert.equal(topology.primary, primary);
      assert.deepEqual(topology.replicas, members.filter((name) => name !== primary));
    }
  }
});
test("missing and invalid topology fail closed", () => {
  assert.throws(() => membersFromDocument(document(), names.slice(0, 2)), /Missing member contexts/);
  assert.throws(() => membersFromDocument(document("unknown"), names), /valid replication topology/);
  assert.throws(() => membersFromDocument(document(names[0], [names[0], names[0]]), names), /valid replication topology/);
});
test("CNPG discovery uses ownership, never the first unrelated database", () => {
  const foreign = { metadata: { name: "unrelated" } };
  const own = { metadata: { name: "demo-db", ownerReferences: [{ kind: "DocumentDB", name: "demo", apiVersion: "documentdb.io/preview" }] } };
  assert.equal(selectCNPGCluster([foreign, own], "demo"), own);
  assert.equal(selectCNPGCluster([foreign], "demo"), null);
  assert.throws(() => selectCNPGCluster([own, own], "demo"), /Multiple CNPG shards/);
});
test("unhealthy text and zero ready instances are not healthy", () => {
  assert.equal(clusterStatus("a", { status: { phase: "unhealthy", readyInstances: 1, instances: 1 } }, "a").healthy, false);
  assert.equal(clusterStatus("a", { status: { phase: "Cluster in healthy state", readyInstances: 0, instances: 0 } }, "a").healthy, false);
});
test("health probes every replica, including the third member", async () => {
  const visited = [];
  const result = await checkReplication(clusters(), async (member) => {
    visited.push(member.context);
    return member.context === names[2] ? { ok: false, reason: "WAL receiver is not streaming" } : { ok: true };
  });
  assert.deepEqual(visited, names.slice(1));
  assert.equal(result.ok, false);
  assert.equal(result.context, names[2]);
});
test("health refuses unconverged source or stale promotion state", async () => {
  for (const patch of [{ replicaSource: "old-primary" }, { promotionToken: true }, { replicaPrimary: "old-primary" }, { healthy: false }]) {
    const members = clusters();
    Object.assign(members[1], patch);
    assert.equal((await checkReplication(members, async () => ({ ok: true }))).ok, false);
  }
});
test("regional switchover uses the supported plugin and no force or CNPG patch", async () => {
  for (const target of names.slice(1)) {
    let args;
    const handler = createPromotionHandler({
      getTopology: async () => ({ ...membersFromDocument(document(), names), clusters: clusters() }),
      checkHealth: async () => ({ ok: true }), kubectl: async (value) => { args = value; return { code: 0 }; },
      invalidate: () => {}, namespace: "demo-ns", resource: "demo", hubContext: "hub",
    });
    const res = response();
    await handler({ body: { target } }, res);
    assert.equal(res.body.ok, true);
    assert.deepEqual(args, ["documentdb", "promote", "--documentdb", "demo", "--namespace", "demo-ns",
      "--hub-context", "hub", "--target-cluster", target, "--cluster-context", target, "--wait-timeout", "10m"]);
  }
});
test("promotion rejects unknown, primary, force, and unhealthy targets without mutations", async () => {
  let health = true;
  const handler = createPromotionHandler({
    getTopology: async () => ({ ...membersFromDocument(document(), names), clusters: clusters() }),
    checkHealth: async () => ({ ok: health, reason: "not streaming" }),
    kubectl: async () => assert.fail("must not mutate"), invalidate: () => {},
  });
  for (const body of [{ target: "unknown" }, { target: names[0] }, { target: names[1], force: true }]) {
    const res = response(); await handler({ body }, res); assert.equal(res.statusCode, 400);
  }
  health = false;
  const res = response(); await handler({ body: { target: names[1] } }, res); assert.equal(res.statusCode, 409);
});
test("concurrent promotion is serialized and CLI failure is reported", async () => {
  let finish;
  const waiting = new Promise((resolve) => { finish = resolve; });
  const handler = createPromotionHandler({
    getTopology: async () => ({ ...membersFromDocument(document(), names), clusters: clusters() }),
    checkHealth: async () => ({ ok: true }), kubectl: async () => waiting, invalidate: () => {},
  });
  const first = response();
  const work = handler({ body: { target: names[1] } }, first);
  const second = response();
  await handler({ body: { target: names[2] } }, second);
  assert.equal(second.statusCode, 409);
  finish({ code: -1, stderr: "timed out" });
  await work;
  assert.equal(first.statusCode, 502);
  assert.equal(first.body.ok, false);
});
