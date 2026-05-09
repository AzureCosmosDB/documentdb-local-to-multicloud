import { MongoClient } from "mongodb";
const targets = [
  { n:"LOCAL", u:"mongodb://demo:demo@localhost:27017/?tls=true&tlsAllowInvalidCertificates=true" },
  { n:"AKS",   u:"mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57017/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" },
  { n:"EKS",   u:"mongodb://docdb:f4e7723a9db8f333f35257ad61225384@127.0.0.1:57018/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true" },
];
for (const t of targets) {
  const c = new MongoClient(t.u, { serverSelectionTimeoutMS: 8000 });
  try {
    await c.connect();
    const col = c.db("bookingsdb").collection("listings");
    const count = await col.estimatedDocumentCount();
    const sample = await col.findOne({});
    const keys = sample ? Object.keys(sample).filter(k=>k!=="_id").slice(0,8).join(", ") : "(none)";
    const hasAdmin1 = sample ? "admin1" in sample : "n/a";
    console.log(`[${t.n}] count=${count}  first 8 keys: ${keys}  admin1?=${hasAdmin1}`);
  } catch (e) { console.log(`[${t.n}] ERR ${e.message}`); }
  finally { await c.close(); }
}
