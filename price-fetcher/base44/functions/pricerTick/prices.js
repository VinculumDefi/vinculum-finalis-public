// Vinculum price fetcher: price maths, the price lookup, and the lines that
// are written to the Base Verifier.
//
// Lookup order for every asset:
//   1. CoinGecko simple/price by the registry row's pricing identifier.
//   2. If CoinGecko has no price: DexScreener, by the row's own contract on
//      Base. Of the Base pools that hold the token and give it a USD price,
//      the pool with the most liquidity gives the price.
//   3. One row (row 138) may also use a DexScreener pool for its exact
//      contract on another chain.
// There is no lookup by symbol and no substitute or fixed price. An asset
// with no price gets no price.

export const PRICE_DECIMALS = 30;
export const MAX_PRICE_USD30 = 2n ** 128n - 1n;
export const ENVIRONMENT_ID = "Base";
const DS_CHAIN = "base";
const EVM_ADDR = /^0x[0-9a-fA-F]{40}$/;

// The one row that may be priced from a pool on another chain.
export const CROSS_CHAIN_ROW = Object.freeze({
  row: 138,
  address: "0xCF7Fc0De71238c9EC45EC2Fd24FDc8521345dbB5",
});

export function isCrossChainRow(address) {
  return typeof address === "string" && address.toLowerCase() === CROSS_CHAIN_ROW.address.toLowerCase();
}

// USD per whole token as an integer with 30 decimals. Truncated, never
// rounded up. No floating point arithmetic on the value.
export function toUsd30(usd) {
  if (usd === null || usd === undefined) return 0n;
  const s = typeof usd === "number" ? (Number.isFinite(usd) ? usd.toString() : "") : String(usd).trim();
  const m = s.match(/^\+?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/);
  if (!m || (m[1] === "" && (m[2] === undefined || m[2] === ""))) return 0n;
  const intPart = m[1] || "0";
  const fracPart = m[2] || "";
  const exp = m[3] ? parseInt(m[3], 10) : 0;
  if (!Number.isSafeInteger(exp) || Math.abs(exp) > 1000) return 0n;
  const digits = BigInt(intPart + fracPart);
  const shift = exp - fracPart.length + PRICE_DECIMALS;
  return shift >= 0 ? digits * 10n ** BigInt(shift) : digits / 10n ** BigInt(-shift);
}

// 30-decimal integer to a readable USD string.
export function usd30ToString(p) {
  const s = BigInt(p).toString().padStart(PRICE_DECIMALS + 1, "0");
  const i = s.slice(0, -PRICE_DECIMALS);
  const f = s.slice(-PRICE_DECIMALS).replace(/0+$/, "");
  return f ? i + "." + f : i;
}

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

// Exact decimal string of a number or string from a price service.
export function decimalString(v) {
  let s = String(v).trim();
  const m = s.match(/^(\d+)(?:\.(\d+))?e([+-]?\d+)$/i);
  if (m) {
    const digits = m[1] + (m[2] || "");
    const exp = Number(m[3]);
    const point = m[1].length + exp;
    s = point <= 0
      ? "0." + "0".repeat(-point) + digits
      : point >= digits.length
        ? digits + "0".repeat(point - digits.length)
        : digits.slice(0, point) + "." + digits.slice(point);
    s = s.replace(/^0+(?=\d)/, "");
  }
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  return s.includes(".") ? s.replace(/0+$/, "").replace(/\.$/, "") : s;
}

export function rowAddress(row) {
  if (row.kind === "native") return null;
  const id = String(row.identifier || "").trim();
  return EVM_ADDR.test(id) ? id : null;
}

// DexScreener pools that hold the token and give it a USD price, most
// liquidity first.
export function dsPairs(address, pairs, { anyChain = false } = {}) {
  const out = [];
  const seen = new Set();
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  for (const p of Array.isArray(pairs) ? pairs : []) {
    if (!anyChain && p.chainId && p.chainId !== DS_CHAIN) continue;
    const key = String(p.chainId || "") + "|" + String(p.pairAddress || "").toLowerCase();
    if (p.pairAddress && seen.has(key)) continue;
    seen.add(key);
    const base = same(p.baseToken && p.baseToken.address, address);
    const quote = same(p.quoteToken && p.quoteToken.address, address);
    if (!base && !quote) continue;
    let price = null;
    if (base && num(p.priceUsd) > 0) price = decimalString(p.priceUsd);
    else if (quote && num(p.priceUsd) > 0 && num(p.priceNative) > 0) price = decimalString(String(num(p.priceUsd) / num(p.priceNative)));
    if (!price) continue;
    out.push({
      address: String(p.pairAddress || "").toLowerCase(),
      chain: p.chainId || null,
      liquidityUsd: num((p.liquidity || {}).usd),
      side: base ? "base" : "quote",
      price,
    });
  }
  return out.sort((x, y) => y.liquidityUsd - x.liquidityUsd);
}

// One HTTP GET with a small number of tries. 429 and 5xx and network errors
// are tried again after a wait. 404 is "nothing there". Any other answer is
// an error.
export async function getJson(http, url, headers, { tries = 3, waitMs = 5000, sleep, mayContinue = () => true } = {}) {
  let last = "no attempt";
  for (let i = 0; i < tries; i++) {
    if (i > 0) {
      if (!mayContinue()) break;
      await sleep(waitMs * i);
    }
    try {
      const r = await http(url, headers);
      if (r.status === 200) {
        try {
          return { ok: true, json: JSON.parse(r.body) };
        } catch {
          last = "answer was not JSON";
          continue;
        }
      }
      if (r.status === 404) return { ok: true, json: null };
      last = "HTTP " + r.status;
      if (r.status !== 429 && r.status < 500) break;
    } catch (e) {
      last = "network: " + (e && e.message ? e.message : String(e));
    }
  }
  return { ok: false, error: last };
}

const COINGECKO = "https://api.coingecko.com/api/v3";
const DEXSCREENER = "https://api.dexscreener.com";
// DexScreener often answers "too many requests" for a moment. Each lookup is
// tried three times, 4 and then 8 seconds apart, before it counts as failed.
const DEX_TRY = { tries: 3, waitMs: 4000 };

// Prices one group of registry rows. Returns one result for every row:
// a price with its source, or a reason there is none.
//
// cgError is set when CoinGecko did not give a usable answer at all (as
// opposed to answering without a price for some asset). The caller decides
// whether to try the group again later.
//
// While dexAfterCgFailure is false, a CoinGecko failure ends the call there,
// so the group can be tried again later without asking DexScreener for every
// asset in it.
export async function fetchGroup(rows, { http, sleep, now, cgKey = "", budgetEndsAt = Infinity, dexPauseMs = 400, dexAfterCgFailure = true }) {
  const headers = cgKey ? { "x-cg-demo-api-key": cgKey } : {};
  const mayContinue = () => now() < budgetEndsAt;
  const ids = [...new Set(rows.map((r) => r.pricingIdentifier).filter(Boolean))];
  let quotes = {};
  let cgError = null;
  const fetchedAt = new Date(now()).toISOString();
  if (ids.length) {
    const url = COINGECKO + "/simple/price?ids=" + encodeURIComponent(ids.join(",")) + "&vs_currencies=usd&include_last_updated_at=true";
    const res = await getJson(http, url, headers, { sleep, mayContinue });
    if (!res.ok) cgError = res.error;
    else if (!res.json || typeof res.json !== "object" || Array.isArray(res.json)) cgError = "answer was not a price list";
    else if (Object.keys(res.json).length === 0) cgError = "answer was empty";
    else quotes = res.json;
  }
  if (cgError && !dexAfterCgFailure) return { cgError, results: [] };

  const results = [];
  for (const r of rows) {
    const base = { row: r.row, symbol: r.symbol, canonicalAssetId: r.canonicalAssetId };
    const q = r.pricingIdentifier ? quotes[r.pricingIdentifier] : null;
    const cgUsd = q && num(q.usd) > 0 ? decimalString(q.usd) : null;
    if (cgUsd) {
      results.push({ ...base, usd: cgUsd, source: "CoinGecko", fetchedAt, reason: null });
      continue;
    }
    const cgWhy = !r.pricingIdentifier
      ? "no CoinGecko identifier"
      : cgError
        ? "CoinGecko did not answer (" + cgError + ")"
        : "CoinGecko has no USD price";
    const address = rowAddress(r);
    if (!address) {
      results.push({ ...base, usd: null, source: null, reason: cgError && r.pricingIdentifier ? "fetch_error" : "no_price", detail: cgWhy });
      continue;
    }
    if (!mayContinue()) {
      results.push({ ...base, usd: null, source: null, reason: "fetch_error", notTried: true, detail: cgWhy + "; out of time before DexScreener" });
      continue;
    }
    const cross = isCrossChainRow(address);
    let pools = null;
    let dsError = null;
    const own = await getJson(http, DEXSCREENER + "/token-pairs/v1/" + DS_CHAIN + "/" + address, {}, { ...DEX_TRY, sleep, mayContinue });
    if (!own.ok) dsError = own.error;
    else {
      let raw = Array.isArray(own.json) ? own.json : [];
      if (cross) {
        await sleep(dexPauseMs);
        const all = await getJson(http, DEXSCREENER + "/latest/dex/tokens/" + address, {}, { ...DEX_TRY, sleep, mayContinue });
        if (!all.ok) dsError = all.error;
        else raw = raw.concat(all.json && Array.isArray(all.json.pairs) ? all.json.pairs : []);
      }
      if (!dsError) pools = dsPairs(address, raw, { anyChain: cross });
    }
    await sleep(dexPauseMs);
    if (pools && pools.length) {
      const p = pools[0];
      results.push({ ...base, usd: p.price, source: "DexScreener", fetchedAt: new Date(now()).toISOString(), pool: p.address, poolChain: p.chain, reason: null });
      continue;
    }
    const dsWhy = dsError ? "DexScreener did not answer (" + dsError + ")" : "DexScreener has no pool with a USD price";
    results.push({
      ...base,
      usd: null,
      source: null,
      reason: dsError || (cgError && r.pricingIdentifier) ? "fetch_error" : "no_price",
      detail: cgWhy + "; " + dsWhy,
    });
  }
  return { cgError, results };
}

// Everything that needs the ethers library: the asset key the Verifier uses
// and the encoded call.
export function makeCodec(ethers) {
  const ABI = [
    "function applyScheduledPriceRun(uint64 runId, (string environmentId, bytes32 canonicalAssetId, uint256 priceUsd30, bool success)[] updates)",
  ];
  const iface = new ethers.Interface(ABI);
  const assetKey = (canonicalAssetId) => ethers.solidityPackedKeccak256(["string", "bytes32"], [ENVIRONMENT_ID, canonicalAssetId]);
  const encodeRun = (runId, lines) =>
    iface.encodeFunctionData("applyScheduledPriceRun", [
      BigInt(runId),
      lines.map((l) => ({
        environmentId: ENVIRONMENT_ID,
        canonicalAssetId: l.canonicalAssetId,
        priceUsd30: BigInt(l.priceUsd30),
        success: l.success,
      })),
    ]);
  const hash = (hex) => ethers.keccak256(hex);
  return { ABI, iface, assetKey, encodeRun, hash };
}

// Decides what to write for each asset.
//   valid price                          -> a price line
//   no valid price, asset usable on chain -> an "unavailable" line, which
//                                            pauses new locks of that asset
//                                            until a later run prices it
//   no valid price, already unavailable   -> nothing to write
export function planLines(results, onchain, assetKey) {
  const seen = new Set();
  const plan = [];
  for (const f of results) {
    const key = assetKey(f.canonicalAssetId);
    if (seen.has(key)) throw new Error("duplicate asset in group: row " + f.row);
    seen.add(key);
    const cur = onchain.get(key);
    if (!cur) throw new Error("no on-chain reading for row " + f.row);
    const p = toUsd30(f.usd);
    const valid = p > 0n && p <= MAX_PRICE_USD30;
    let action;
    let why = null;
    if (valid) action = "post-price";
    else {
      why = f.usd == null
        ? (f.reason || "no_price") + (f.detail ? ": " + f.detail : "")
        : p === 0n
          ? "price rounds to 0 at 30 decimals"
          : "price above the largest storable value";
      action = cur.usable ? "post-unavailable" : "skip-already-unavailable";
    }
    plan.push({
      row: f.row,
      symbol: f.symbol,
      canonicalAssetId: f.canonicalAssetId,
      key,
      action,
      priceUsd30: valid ? p : 0n,
      usd: valid ? usd30ToString(p) : null,
      source: valid ? f.source : null,
      why,
    });
  }
  return plan;
}

export function linesOf(plan) {
  return plan
    .filter((p) => p.action === "post-price" || p.action === "post-unavailable")
    .map((p) => ({
      canonicalAssetId: p.canonicalAssetId,
      priceUsd30: (p.action === "post-price" ? p.priceUsd30 : 0n).toString(),
      success: p.action === "post-price",
    }));
}
