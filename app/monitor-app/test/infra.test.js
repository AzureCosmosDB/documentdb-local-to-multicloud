const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const bash = process.env.BASH_BIN || (process.platform === "win32" ? "C:\\Program Files\\Git\\bin\\bash.exe" : "bash");
const cwd = path.resolve(__dirname, "..", "..", "..");
function render(extra = {}) {
  return spawnSync(bash, ["infra/multi-cloud/deploy-documentdb.sh", "--render"], {
    cwd, encoding: "utf8", env: { ...process.env, INCLUDE_EKS: "true", INCLUDE_GKE: "false",
      INCLUDE_AKS_REPLICA: "false", AKS_REPLICA_REGION: "", PRIMARY_CLUSTER: "",
      DOCUMENTDB_PASSWORD: "test&password/with:quotes'\"", ...extra },
  });
}
test("default deployment keeps AKS and EKS, with scoped placement and pinned engine", () => {
  const result = render();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /name: azure-documentdb\n/);
  assert.match(result.stdout, /name: aws-documentdb\n/);
  assert.doesNotMatch(result.stdout, /name: azure-documentdb-secondary/);
  assert.match(result.stdout, /placementType: PickFixed/);
  assert.match(result.stdout, /documentDBVersion: "1.0.0"/);
  assert.doesNotMatch(result.stdout, /\{\{/);
  assert.match(result.stdout, new RegExp(Buffer.from("test&password/with:quotes'\"").toString("base64").replace(/[+]/g, "\\+")));
});
test("Azure-only deployment includes exactly two AKS members and selected primary", () => {
  const result = render({ INCLUDE_EKS: "false", INCLUDE_AKS_REPLICA: "true", AKS_REPLICA_REGION: "westus3", PRIMARY_CLUSTER: "azure-documentdb-secondary" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal((result.stdout.match(/environment: aks/g) || []).length, 2);
  assert.doesNotMatch(result.stdout, /aws-documentdb|environment: eks/);
  assert.match(result.stdout, /primary: azure-documentdb-secondary/);
});
test("combined topology has three distinct members", () => {
  const result = render({ INCLUDE_AKS_REPLICA: "true", AKS_REPLICA_REGION: "westus3" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal((result.stdout.match(/environment:/g) || []).length, 3);
});
test("invalid region, names, flags and primary fail before calling any cloud CLI", () => {
  for (const env of [
    { INCLUDE_AKS_REPLICA: "true" },
    { INCLUDE_AKS_REPLICA: "true", AKS_REPLICA_REGION: "eastus2" },
    { EKS_CLUSTER_NAME: "azure-documentdb" }, { INCLUDE_EKS: "no" },
    { PRIMARY_CLUSTER: "missing" }, { INCLUDE_EKS: "false" },
  ]) {
    const result = render(env);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /ERROR:/);
  }
});
