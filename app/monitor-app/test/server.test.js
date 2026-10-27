const { test } = require("node:test");
const assert = require("node:assert/strict");

test("Express 5 serves the UI and rejects unsafe/invalid requests without cluster access", async (t) => {
  Object.assign(process.env, {
    DDB_NAMESPACE: "test", DDB_RESOURCE: "test", DDB_HUB_CONTEXT: "unused",
    DDB_MEMBER_CONTEXTS: "azure-documentdb,azure-documentdb-secondary", DDB_LEGACY_RECOVERY: "false",
    KUBECTL_BIN: "must-not-run-kubectl-during-tests",
  });
  const { app } = require("../server");
  const server = app.listen(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const html = await (await fetch(base)).text();
  for (const tab of ["Topology", "Bookings", "Vector Search", "Load"]) assert.ok(html.includes(`>${tab}</button>`));
  assert.equal((await (await fetch(`${base}/api/loadgen/status`)).json()).status.running, false);
  for (const [endpoint, body, expected] of [
    ["vector-search", { q: "" }, 400], ["promote", { target: "azure-documentdb-secondary", force: true }, 400],
    ["force-promote-local-token", { context: "azure-documentdb" }, 409], ["clear-stale-token", {}, 409],
  ]) {
    const res = await fetch(`${base}/api/${endpoint}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    });
    assert.equal(res.status, expected);
    assert.equal((await res.json()).ok, false);
  }
});
