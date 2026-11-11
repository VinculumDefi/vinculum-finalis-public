// Builds base44/functions/pricerTick/registry.json from the Base registry
// document (Revision E). It keeps only the fields the pricer reads and leaves
// out the two excluded Base contracts. From the price-fetcher folder, run:
//   node pricer-tools/build-registry.mjs
// It reads registry/assets.full-revE.json at the root of this repository.
// You may also pass a different path to the registry document.
import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXCLUDED = [
  "0xfca95aeb5bf44ae355806a5ad14659c940dc6bf7",
  "0x041fdf3f472d2c8a7ecc458fc3b7f543e6c57ef7",
];
const here = path.dirname(fileURLToPath(import.meta.url));
const src = process.argv[2] || path.join(here, "..", "..", "registry", "assets.full-revE.json");
const raw = fs.readFileSync(src);
const doc = JSON.parse(raw.toString("utf8"));
if (doc.assets.length !== doc.count) throw new Error("registry count mismatch");
if (doc.assets.some((a) => a.environmentId !== "Base")) throw new Error("registry has a row that is not Base");
const excluded = new Set(EXCLUDED);
const assets = doc.assets
  .filter((a) => !excluded.has(String(a.identifier || "").trim().toLowerCase()))
  .map((a) => ({
    row: a.row,
    symbol: a.symbol,
    canonicalAssetId: a.canonicalAssetId,
    identifier: a.identifier,
    kind: a.kind,
    pricingIdentifier: a.pricingIdentifier || null,
  }));
const seen = new Set();
for (const a of assets) {
  if (seen.has(a.canonicalAssetId)) throw new Error("duplicate asset id at row " + a.row);
  seen.add(a.canonicalAssetId);
}
const out = {
  environmentId: "Base",
  registry: "Base asset registry, Revision E",
  registrySha256: doc.registrySha256,
  sourceRows: doc.count,
  excludedContracts: EXCLUDED,
  count: assets.length,
  assets,
};
const dest = path.join(here, "..", "base44", "functions", "pricerTick", "registry.json");
fs.writeFileSync(dest, JSON.stringify(out) + "\n");
console.log("source rows " + doc.count + ", written rows " + assets.length + ", source file sha256 " + crypto.createHash("sha256").update(raw).digest("hex"));
