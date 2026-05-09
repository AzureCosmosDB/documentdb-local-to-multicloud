import { MongoClient } from "mongodb";
const c = new MongoClient("mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true");
await c.connect();
const col = c.db("bookingsdb").collection("listings");

const probes = [
  ["city + price",          { city: "Denver", price: { $lt: 250 } }],
  ["bathrooms eq",          { bathrooms: 2 }],
  ["bathrooms range",       { bathrooms: { $gte: 2 } }],
  ["amenities $all",        { amenities: { $all: ["Wifi", "Kitchen"] } }],
  ["room_type + bedrooms",  { room_type: "Entire home/apt", bedrooms: { $gte: 2 } }],
  ["beds eq",               { beds: 3 }],
  ["country + bedrooms",    { country: "United States", bedrooms: { $gte: 3 } }],
];
for (const [label, q] of probes) {
  const expl = await col.find(q).explain("executionStats");
  const stats = expl.executionStats || {};
  const winning = expl.queryPlanner?.winningPlan?.inputStage?.stage || expl.queryPlanner?.winningPlan?.stage;
  console.log(`${label}: hits=${stats.nReturned} examined=${stats.totalDocsExamined} ms=${stats.executionTimeMillis} stage=${winning}`);
}
await c.close();
