import { MongoClient } from "mongodb";
const c = new MongoClient("mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true");
await c.connect();
const col = c.db("bookingsdb").collection("listings");

const probes = [
  ["regex on neighborhood_summary 'mountain'", { neighborhood_summary: { $regex: "mountain", $options: "i" } }],
  ["regex on search_text 'kitchen'",          { search_text: { $regex: "kitchen", $options: "i" } }],
  ["regex on search_text 'ski'",              { search_text: { $regex: "ski", $options: "i" } }],
  ["regex on search_text 'rooftop'",          { search_text: { $regex: "rooftop", $options: "i" } }],
];
for (const [label, q] of probes) {
  const expl = await col.find(q).explain("executionStats");
  const stats = expl.executionStats || {};
  console.log(`${label}: hits=${stats.nReturned} examined=${stats.totalDocsExamined} ms=${stats.executionTimeMillis}`);
}
await c.close();
