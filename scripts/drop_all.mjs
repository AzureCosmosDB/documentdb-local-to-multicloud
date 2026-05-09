import { MongoClient } from "mongodb";

const targets = [
  { name: "LOCAL", uri: "mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" },
  { name: "AKS",   uri: "mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" },
  { name: "EKS",   uri: "mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57018/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" },
];

for (const t of targets) {
  const c = new MongoClient(t.uri, { serverSelectionTimeoutMS: 8000 });
  try {
    await c.connect();
    const db = c.db("bookingsdb");
    const before = await db.collection("listings").estimatedDocumentCount().catch(()=>0);
    if (t.name === "EKS") {
      console.log(`[${t.name}] before drop: ${before} (read-only / replica — letting WAL handle drop)`);
    } else {
      try { await db.collection("listings").drop(); console.log(`[${t.name}] dropped listings (had ${before})`); }
      catch (e) { console.log(`[${t.name}] drop noop:`, e.message); }
    }
  } finally { await c.close(); }
}
