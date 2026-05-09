import { MongoClient } from "mongodb";
const c = new MongoClient("mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true");
await c.connect();
const col = c.db("bookingsdb").collection("listings");

const probes = [
  ["bathrooms + price",            { bathrooms: { $gte: 2 }, price: { $lt: 300 } }],
  ["beds eq + price range",        { beds: 3, price: { $lt: 250 } }],
  ["amenities $all 3 things",      { amenities: { $all: ["Wifi", "Kitchen", "Free parking on premises"] } }],
  ["bathrooms eq 3",               { bathrooms: 3 }],
  ["beds eq 4",                    { beds: 4 }],
];
for (const [label, q] of probes) {
  const expl = await col.find(q).explain("executionStats");
  const stats = expl.executionStats || {};
  const wp = expl.queryPlanner?.winningPlan;
  // walk the plan
  const stages = [];
  let s = wp; while (s) { stages.push(s.stage); s = s.inputStage; }
  console.log(`${label}: hits=${stats.nReturned} examined=${stats.totalDocsExamined} ms=${stats.executionTimeMillis} plan=${stages.join("->")}`);
}
await c.close();
