// Reorder fields in data/listings_vectors.json so demo-friendly fields land
// at the top (displayName, city, country) and the bulky descriptionVector
// goes last. Drops the admin1 field.
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const file = resolve(__dir, "..", "data", "listings_vectors.json");
const backup = file + ".bak-reorder";

console.log("Reading", file);
const docs = JSON.parse(readFileSync(file, "utf-8"));
console.log("Backing up to", backup);
copyFileSync(file, backup);

// Desired order: identity + display first, then geo, then attributes,
// then long-text fields, then the big vector last.
const order = [
  "id",
  "name",
  "displayName",
  "city",
  "country",
  "latitude",
  "longitude",
  "price",
  "property_type",
  "room_type",
  "bedrooms",
  "beds",
  "bathrooms",
  "amenities",
  "tags",
  "neighborhood_summary",
  "neighborhood_overview",
  "search_text",
  "descriptionVector",
];

const reorder = (d) => {
  const out = {};
  for (const k of order) if (k in d) out[k] = d[k];
  // append any other unexpected keys (defensive), but skip admin1
  for (const k of Object.keys(d)) {
    if (k === "admin1") continue;
    if (!(k in out)) out[k] = d[k];
  }
  return out;
};

const reordered = docs.map(reorder);
writeFileSync(file, JSON.stringify(reordered));
console.log("Wrote", reordered.length, "reordered docs.");
console.log("Sample first doc keys (in order):", Object.keys(reordered[0]).join(", "));
