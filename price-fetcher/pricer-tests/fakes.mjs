// Stand-ins for Base44 storage, the price services, the chain and the clock.
import { ethers } from "ethers";
import { makeCodec, ENVIRONMENT_ID } from "../base44/functions/pricerTick/prices.js";
import { DEFAULTS } from "../base44/functions/pricerTick/core.js";

export const codec = makeCodec(ethers);
export const POSTER = "0x60013cD1aF9e81B083aa13eCDe5F491771db0DB4";

export function makeClock(start) {
  let t = start;
  return { now: () => t, sleep: async (ms) => { t += ms; }, advance: (ms) => { t += ms; }, set: (v) => { t = v; } };
}

export function makeStore() {
  let id = 0;
  const db = { state: null, runs: [], groups: [] };
  const patch = async (rec, data) => { Object.assign(rec, structuredClone(data)); };
  return {
    db,
    async loadState() { return (db.state ??= { id: ++id, lock_token: "", lease_until: 0, current_run_key: "", last_fetch_at: 0, created_at_ms: 0 }); },
    async claim(state, token, now, lease) {
      if (state.lock_token && state.lease_until > now) return false;
      state.lock_token = token; state.lease_until = now + lease; return true;
    },
    async release(state, token) { if (state.lock_token === token) { state.lock_token = ""; state.lease_until = 0; } },
    patchState: patch,
    async findRun(key) { return db.runs.find((r) => r.run_key === key) || null; },
    async createRun(data) { const r = { id: ++id, ...structuredClone(data) }; db.runs.push(r); return r; },
    patchRun: patch,
    async recentRuns(n) { return [...db.runs].reverse().slice(0, n); },
    async groupsOf(key) { return db.groups.filter((g) => g.run_key === key); },
    async createGroup(data) { const g = { id: ++id, ...structuredClone(data) }; db.groups.push(g); return g; },
    patchGroup: patch,
    async deleteGroup(g) { db.groups.splice(db.groups.indexOf(g), 1); },
  };
}

// A model of the Verifier's price write, plus a poster wallet.
export function makeChain({ signer = POSTER, balance = 10n ** 16n } = {}) {
  const c = {
    prices: new Map(), last: 1n, nonceNow: 7, balanceWei: balance, sent: [], mined: [], signer,
    behaviour: "mine", // mine | drop | throw | mine-silently | revert
    costWei: 70000000000000n,
    get(key) { return c.prices.get(key) || { priceUsd30: 0n, usable: false }; },
    signerAddress: () => c.signer,
    poster: async () => POSTER,
    lastRunId: async () => c.last,
    balance: async () => c.balanceWei,
    nonce: async () => c.nonceNow,
    readPrices: async (keys) => new Map(keys.map((k) => [k, { ...c.get(k) }])),
    simulate: async (calldata) => { const [runId] = codec.iface.decodeFunctionData("applyScheduledPriceRun", calldata); if (runId !== c.last + 1n) throw new Error("wrong run number"); },
    estimate: async () => ({ gasLimit: 14000000n, costWei: c.costWei }),
    apply(tx) {
      if (tx.nonce !== c.nonceNow) return false;
      c.nonceNow++;
      const [runId, updates] = codec.iface.decodeFunctionData("applyScheduledPriceRun", tx.calldata);
      if (runId !== c.last + 1n) { c.receipts.set(tx.hash, { status: 0, blockNumber: 1 }); return true; }
      for (const u of updates) {
        if (u.environmentId !== ENVIRONMENT_ID) throw new Error("wrong environment");
        c.prices.set(codec.assetKey(u.canonicalAssetId), u.success ? { priceUsd30: u.priceUsd30, usable: true } : { priceUsd30: 0n, usable: false });
      }
      c.last = runId;
      c.mined.push({ ...tx, runId, lines: updates.length });
      c.receipts.set(tx.hash, { status: 1, blockNumber: 1 });
      return true;
    },
    receipts: new Map(),
    pending: [],
    async send(tx) {
      if (!c.signer) throw new Error("no key");
      if (c.behaviour === "throw") throw new Error("could not reach the node");
      const hash = "0x" + String(c.sent.length + 1).padStart(64, "0");
      const full = { ...tx, hash };
      c.sent.push(full);
      if (c.behaviour === "drop") return hash;
      if (c.behaviour === "revert") { c.nonceNow++; c.receipts.set(hash, { status: 0, blockNumber: 1 }); return hash; }
      if (c.behaviour === "mine-silently") { c.pending.push(full); return hash; }
      c.apply(full);
      return hash;
    },
    async waitReceipt(hash) {
      if (c.behaviour === "mine-silently") { for (const tx of c.pending.splice(0)) c.apply(tx); return null; }
      return c.receipts.get(hash) || null;
    },
    receipt: async (hash) => c.receipts.get(hash) || null,
  };
  return c;
}

// Price services. cg: id -> usd. dex: lowercased contract -> pairs array.
export function makeHttp(clock) {
  const h = { cg: {}, dex: {}, dexBusy: {}, cgDown: false, dexDown: false, calls: [], cgIdsSeen: [] };
  h.get = async (url, headers) => {
    h.calls.push({ url, at: clock.now(), headers });
    if (url.includes("coingecko.com")) {
      if (h.cgDown) return { status: 503, body: "" };
      const ids = decodeURIComponent(url.split("ids=")[1].split("&")[0]).split(",");
      h.cgIdsSeen.push(...ids);
      const out = {};
      for (const id of ids) if (h.cg[id] !== undefined) out[id] = { usd: h.cg[id], last_updated_at: 1 };
      return { status: 200, body: JSON.stringify(out) };
    }
    if (h.dexDown) return { status: 503, body: "" };
    const address = url.split("/").pop().toLowerCase();
    if ((h.dexBusy[address] || 0) > 0) { h.dexBusy[address]--; return { status: 429, body: "" }; }
    if (url.includes("/latest/dex/tokens/")) return { status: 200, body: JSON.stringify({ pairs: h.dex["any:" + address] || [] }) };
    return { status: 200, body: JSON.stringify(h.dex[address] || []) };
  };
  return h;
}

export function makeDeps({ registry, start, cfg = {}, chain = makeChain() }) {
  const clock = makeClock(start);
  const store = makeStore();
  const http = makeHttp(clock);
  const alerts = [];
  let n = 0;
  const deps = {
    cfg: { ...DEFAULTS, enabled: true, ...cfg },
    store, clock, registry, chain, codec,
    http: http.get,
    newToken: () => "token-" + ++n,
    log: () => {},
    alert: async (subject, body) => { alerts.push({ subject, body }); },
  };
  return { deps, clock, store, http, chain, alerts };
}

// A small registry: n token rows with CoinGecko ids, plus the listed extras.
export function tinyRegistry(n, extras = []) {
  const assets = [];
  for (let i = 0; i < n; i++) {
    assets.push({ row: 1000 + i, symbol: "T" + i, canonicalAssetId: ethers.id("asset-" + i), identifier: ethers.getAddress("0x" + (i + 1).toString(16).padStart(40, "0")), kind: "token", pricingIdentifier: "coin-" + i });
  }
  return { environmentId: "Base", count: n + extras.length, assets: [...assets, ...extras] };
}
