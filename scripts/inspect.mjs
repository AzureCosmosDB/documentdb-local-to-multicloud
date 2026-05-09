import { readFileSync } from "node:fs";
const docs = JSON.parse(readFileSync("../data/listings_vectors.json","utf-8"));
const types = {};
for (const d of docs) types[d.property_type] = (types[d.property_type]||0)+1;
console.log("property_type values:", types);
const prices = docs.map(d=>d.price).filter(p=>typeof p==="number");
console.log("price min/max/sample:", Math.min(...prices), Math.max(...prices), prices.slice(0,5));
console.log("docs with price<200:", prices.filter(p=>p<200).length);
