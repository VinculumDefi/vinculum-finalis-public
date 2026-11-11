// Vinculum price fetcher, Base44 function.
//
// A scheduled workflow calls this function every few minutes. Each call does
// one small piece of a price run and saves where it got to (see core.js).
//
// Calls:
//   { }                    one step of the run. Safe to call at any time and
//                          by anyone: the saved state decides whether there
//                          is anything to do, and steps are spaced out.
//   { "mode": "status" }   a short public summary for the website.
//   { "mode": "detail" }   admin only: the current run and its groups.
//   { "mode": "start" }    admin only: start a run now.
//
// Settings are Base44 secrets. All are optional except where noted:
//   PRICER_ENABLED          "true" turns the fetcher on. Anything else: off.
//   PRICER_POSTING          "true" lets it sign and send. Anything else:
//                           it fetches and records only.
//   POSTER_PRIVATE_KEY      needed only for posting. Never logged or stored.
//   COINGECKO_API_KEY       CoinGecko Demo key.
//   BASE_RPC_URL            private Base RPC. Public ones are used otherwise.
//   PRICER_ALERT_EMAIL      where alerts are sent.
//   PRICER_INTERVAL_HOURS   hours between runs, 12 to 168. Default "18".
//   PRICER_MAX_TX_COST_ETH  most one transaction may cost. Default "0.0003".

import { createClientFromRequest } from "npm:@base44/sdk@0.8.54";
import { ethers } from "npm:ethers@6.17.0";
import { secrets } from "base44:runtime";
import { DEFAULTS, VERSION, tick, publicStatus } from "./core.js";
import { makeCodec } from "./prices.js";
import { makeBaseProvider } from "./rpc.js";
import registry from "./registry.json" with { type: "json" };

const VERIFIER = "0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2";
const CHAIN_ID = 8453;
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
const GAS_PRICE_ORACLE = "0x420000000000000000000000000000000000000F";
const PUBLIC_RPCS = [
  "https://mainnet.base.org",
  "https://base-rpc.publicnode.com",
  "https://base.llamarpc.com",
  "https://base.drpc.org",
  "https://1rpc.io/base",
];
const TX_GAS_CAP = 16500000n;
const JOB_KEY = "pricer";

const VERIFIER_ABI = [
  "function scheduledPricePoster() view returns (address)",
  "function lastScheduledRunId() view returns (uint64)",
  "function scheduledPrices(bytes32) view returns (uint256 priceUsd30, bool usable)",
];
const MC_ABI = ["function aggregate3((address target, bool allowFailure, bytes callData)[] calls) view returns ((bool success, bytes returnData)[])"];
const GPO_ABI = ["function getL1Fee(bytes) view returns (uint256)"];

const secret = (name: string): string => String(secrets.get(name) ?? "").trim();
const rows = (r: any): any[] => (Array.isArray(r) ? r : r?.items ?? []);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function settings() {
  const hours = Number(secret("PRICER_INTERVAL_HOURS") || DEFAULTS.intervalHours);
  const cap = secret("PRICER_MAX_TX_COST_ETH");
  return {
    ...DEFAULTS,
    enabled: secret("PRICER_ENABLED") === "true",
    posting: secret("PRICER_POSTING") === "true",
    coingeckoKey: secret("COINGECKO_API_KEY"),
    // A run can take up to 10 hours to close, so runs are never closer than 12.
    intervalHours: Number.isFinite(hours) && hours >= 12 && hours <= 168 ? hours : DEFAULTS.intervalHours,
    maxTxCostWei: cap ? ethers.parseEther(cap) : DEFAULTS.maxTxCostWei,
  };
}

// Saved state, in three Base44 entities.
function makeStore(base44: any) {
  const E = base44.asServiceRole.entities;
  const patch = async (entity: any, record: any, data: any) => {
    await entity.update(record.id, data);
    Object.assign(record, data);
  };
  return {
    async loadState() {
      const found = rows(await E.PricerState.filter({ job_key: JOB_KEY }));
      if (found.length) return found[0];
      return await E.PricerState.create({ job_key: JOB_KEY, lock_token: "", lease_until: 0, current_run_key: "", last_fetch_at: 0, created_at_ms: Date.now() });
    },
    // One call at a time. The update only succeeds if the lock is still as it
    // was read, so two calls cannot both take it.
    async claim(state: any, token: string, now: number, leaseMs: number) {
      if (state.lock_token && (state.lease_until || 0) > now) return false;
      const res = await E.PricerState.updateMany(
        { id: state.id, lock_token: state.lock_token || "" },
        { $set: { lock_token: token, lease_until: now + leaseMs } },
      );
      if (Number(res?.updated ?? 0) !== 1) return false;
      state.lock_token = token;
      state.lease_until = now + leaseMs;
      return true;
    },
    async release(state: any, token: string) {
      if (state.lock_token !== token) return;
      await patch(E.PricerState, state, { lock_token: "", lease_until: 0 });
    },
    patchState: (state: any, data: any) => patch(E.PricerState, state, data),
    async findRun(key: string) {
      return rows(await E.PricerRun.filter({ run_key: key }))[0] || null;
    },
    createRun: (data: any) => E.PricerRun.create(data),
    patchRun: (run: any, data: any) => patch(E.PricerRun, run, data),
    async recentRuns(n: number) {
      return rows(await E.PricerRun.filter({}, { sort: "-created_date", limit: n }));
    },
    async groupsOf(key: string) {
      return rows(await E.PricerGroup.filter({ run_key: key }, { limit: 500 }));
    },
    createGroup: (data: any) => E.PricerGroup.create(data),
    patchGroup: (group: any, data: any) => patch(E.PricerGroup, group, data),
    deleteGroup: (group: any) => E.PricerGroup.delete(group.id),
  };
}

async function http(url: string, headers: Record<string, string> = {}) {
  const res = await fetch(url, {
    headers: { accept: "application/json", "user-agent": "vinculum-price-fetcher", ...headers },
    signal: AbortSignal.timeout(30000),
  });
  return { status: res.status, body: await res.text() };
}

// The private endpoint, when one is set, is asked first. See rpc.js.
function connect() {
  const urls = [secret("BASE_RPC_URL"), ...PUBLIC_RPCS].filter(Boolean);
  return makeBaseProvider(ethers, urls, CHAIN_ID);
}

// A read that must see a given block is tried again while the node answering
// has not reached that block yet. A real revert is not tried again.
async function pinned<T>(fn: () => Promise<T>, tries = 10): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (e: any) {
      const realRevert = e?.code === "CALL_EXCEPTION" && e?.data && e.data !== "0x";
      if (realRevert || i >= tries) throw e;
      await sleep(2000);
    }
  }
}

function makeChain(provider: any, posting: boolean) {
  const v = new ethers.Interface(VERIFIER_ABI);
  const verifier = new ethers.Contract(VERIFIER, VERIFIER_ABI, provider);
  const multicall = new ethers.Contract(MULTICALL3, MC_ABI, provider);
  const oracle = new ethers.Contract(GAS_PRICE_ORACLE, GPO_ABI, provider);
  let wallet: any = null;
  if (posting) {
    const key = secret("POSTER_PRIVATE_KEY");
    if (key) {
      try {
        wallet = new ethers.Wallet(key.startsWith("0x") ? key : "0x" + key, provider);
      } catch {
        throw new Error("POSTER_PRIVATE_KEY is not a valid key");
      }
    }
  }
  const fees = async (bump: number) => {
    const fee = await provider.getFeeData();
    const mult = BigInt(100 + 25 * bump);
    let tip = ((fee.maxPriorityFeePerGas ?? 0n) * mult) / 100n;
    if (bump > 0 && tip < 100000n) tip = 100000n * BigInt(bump);
    let max = ((fee.maxFeePerGas ?? fee.gasPrice ?? 0n) * mult) / 100n;
    if (max < tip) max = tip;
    return { maxFeePerGas: max, maxPriorityFeePerGas: tip, gasPrice: fee.gasPrice ?? max };
  };
  return {
    signerAddress: () => (wallet ? wallet.address : null),
    poster: async () => ethers.getAddress(await verifier.scheduledPricePoster()),
    lastRunId: async () => BigInt(await verifier.lastScheduledRunId()),
    balance: (address: string) => provider.getBalance(address),
    nonce: (address: string, tag: string) => provider.getTransactionCount(address, tag),
    async readPrices(keys: string[], blockTag?: number) {
      const out = new Map();
      for (let i = 0; i < keys.length; i += 200) {
        const part = keys.slice(i, i + 200);
        const calls = part.map((k) => ({ target: VERIFIER, allowFailure: false, callData: v.encodeFunctionData("scheduledPrices", [k]) }));
        const res: any[] = blockTag === undefined
          ? await multicall.aggregate3(calls)
          : await pinned(() => multicall.aggregate3(calls, { blockTag }));
        res.forEach((r, j) => {
          const [priceUsd30, usable] = v.decodeFunctionResult("scheduledPrices", r.returnData);
          out.set(part[j], { priceUsd30: BigInt(priceUsd30), usable: Boolean(usable) });
        });
      }
      return out;
    },
    async simulate(calldata: string, from: string) {
      await provider.call({ from, to: VERIFIER, data: calldata });
    },
    async estimate(calldata: string, from: string) {
      const gas: bigint = await provider.estimateGas({ from, to: VERIFIER, data: calldata });
      if (gas > TX_GAS_CAP) throw new Error("estimated gas is above the per-transaction limit");
      let gasLimit = (gas * 12n) / 10n;
      if (gasLimit > TX_GAS_CAP) gasLimit = TX_GAS_CAP;
      const f = await fees(0);
      const unsigned = ethers.Transaction.from({ type: 2, chainId: CHAIN_ID, nonce: 0, to: VERIFIER, data: calldata, gasLimit, maxFeePerGas: f.maxFeePerGas, maxPriorityFeePerGas: f.maxPriorityFeePerGas }).unsignedSerialized;
      const l1: bigint = await oracle.getL1Fee(unsigned);
      return { gasLimit, costWei: gas * f.gasPrice + l1 };
    },
    async send({ calldata, nonce, gasLimit, bump }: { calldata: string; nonce: number; gasLimit: bigint; bump: number }) {
      if (!wallet) throw new Error("no poster key is set");
      const f = await fees(bump);
      const tx = await wallet.sendTransaction({ type: 2, chainId: CHAIN_ID, to: VERIFIER, data: calldata, nonce, gasLimit, maxFeePerGas: f.maxFeePerGas, maxPriorityFeePerGas: f.maxPriorityFeePerGas });
      return tx.hash as string;
    },
    async waitReceipt(hash: string, ms: number) {
      try {
        const r = await provider.waitForTransaction(hash, 1, ms);
        return r ? { status: r.status, blockNumber: r.blockNumber } : null;
      } catch {
        return null;
      }
    },
    async receipt(hash: string) {
      const r = await provider.getTransactionReceipt(hash);
      return r ? { status: r.status, blockNumber: r.blockNumber } : null;
    },
  };
}

async function isAdmin(base44: any) {
  try {
    const user = await base44.auth.me();
    return Boolean(user && user.role === "admin");
  } catch {
    return false;
  }
}

export default async function (req: Request): Promise<Response> {
  try {
    const startedAt = Date.now();
    const base44 = createClientFromRequest(req);
    const body: Record<string, unknown> = await req.json().catch(() => ({}));
    const mode = String(body.mode || "tick");
    const cfg = settings();
    const store = makeStore(base44);
    const clock = { now: () => Date.now(), sleep };

    if (mode === "status") return Response.json(await publicStatus({ store, clock, cfg }));

    if (mode === "detail") {
      if (!(await isAdmin(base44))) return Response.json({ error: "Forbidden" }, { status: 403 });
      const state = await store.loadState();
      const run = state.current_run_key ? await store.findRun(state.current_run_key) : (await store.recentRuns(1))[0] || null;
      const groups = run ? (await store.groupsOf(run.run_key)).sort((a: any, b: any) => a.index - b.index) : [];
      return Response.json({
        enabled: cfg.enabled,
        posting: cfg.posting,
        lastError: state.last_error || null,
        run,
        groups: groups.map((g: any) => ({ index: g.index, status: g.status, attempts: g.attempts, note: g.note, priced: g.priced, markedUnavailable: g.marked_unavailable, txHash: g.tx_hash || null })),
      });
    }

    if (mode !== "tick" && mode !== "start") return Response.json({ error: "Unknown mode" }, { status: 400 });
    if (mode === "start" && !(await isAdmin(base44))) return Response.json({ error: "Forbidden" }, { status: 403 });
    if (!cfg.enabled) return Response.json({ did: "off" });

    const alertTo = secret("PRICER_ALERT_EMAIL");
    // The chain is only connected when a step needs it.
    let chain: any = null;
    const getChain = async () => (chain ??= makeChain(connect(), cfg.posting));
    const lazyChain = {
      signerAddress: () => (chain ? chain.signerAddress() : null),
      poster: async () => (await getChain()).poster(),
      lastRunId: async () => (await getChain()).lastRunId(),
      balance: async (a: string) => (await getChain()).balance(a),
      nonce: async (a: string, tag: string) => (await getChain()).nonce(a, tag),
      readPrices: async (keys: string[], blockTag?: number) => (await getChain()).readPrices(keys, blockTag),
      simulate: async (data: string, from: string) => (await getChain()).simulate(data, from),
      estimate: async (data: string, from: string) => (await getChain()).estimate(data, from),
      send: async (tx: any) => (await getChain()).send(tx),
      waitReceipt: async (hash: string, ms: number) => (await getChain()).waitReceipt(hash, ms),
      receipt: async (hash: string) => (await getChain()).receipt(hash),
    };

    const result = await tick(
      {
        cfg,
        store,
        clock,
        registry,
        http,
        chain: lazyChain,
        codec: makeCodec(ethers),
        newToken: () => crypto.randomUUID(),
        log: (m: string) => console.log(m),
        alert: async (subject: string, text: string) => {
          if (!alertTo) return;
          await base44.asServiceRole.integrations.Core.SendEmail({ to: alertTo, subject, body: text });
        },
      },
      { manualStart: mode === "start" },
    );
    return Response.json({ ...result, version: VERSION, tookMs: Date.now() - startedAt });
  } catch (e) {
    return Response.json({ error: e instanceof Error ? e.message : String(e) }, { status: 500 });
  }
}
