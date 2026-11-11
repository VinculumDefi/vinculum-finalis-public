import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { tick, slotFor, runKeyFor, publicStatus, DEFAULTS } from "../base44/functions/pricerTick/core.js";
import { toUsd30, fetchGroup, planLines, linesOf } from "../base44/functions/pricerTick/prices.js";
import { makeDeps, makeChain, tinyRegistry, codec, POSTER } from "./fakes.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const fnDir = path.join(here, "..", "base44", "functions", "pricerTick");
const REGISTRY = JSON.parse(fs.readFileSync(path.join(fnDir, "registry.json"), "utf8"));
const MIN = 60000;
const T0 = Date.UTC(2026, 10, 10, 0, 1); // just after a run time
const H = 3600000;
const ANCHOR = DEFAULTS.anchorMs;

// Call tick every 5 minutes until the run is closed.
async function runToEnd(ctx, { maxTicks = 400, each } = {}) {
  const seen = [];
  for (let i = 0; i < maxTicks; i++) {
    const r = await tick(ctx.deps);
    seen.push(r);
    if (each) await each(r, i);
    if (r.did === "finished") return seen;
    ctx.clock.advance(5 * MIN);
  }
  throw new Error("run did not finish; last: " + JSON.stringify(seen.at(-1)));
}
const priceAll = (ctx, registry, usd = "1.25") => { for (const a of registry.assets) if (a.pricingIdentifier) ctx.http.cg[a.pricingIdentifier] = usd; };
const keyOf = (a) => codec.assetKey(a.canonicalAssetId);

test("registry: 2,891 Base rows, the two excluded contracts are absent", () => {
  assert.equal(REGISTRY.count, 2891);
  assert.equal(REGISTRY.assets.length, 2891);
  assert.equal(REGISTRY.sourceRows, 2893);
  assert.equal(REGISTRY.registrySha256, "af8a4fc62af5be7baf50e2fe164e23202de8e03f1f92103d27b490dcfb56e2e6");
  const ids = new Set(REGISTRY.assets.map((a) => String(a.identifier).toLowerCase()));
  for (const x of REGISTRY.excludedContracts) assert.equal(ids.has(x), false);
  assert.equal(new Set(REGISTRY.assets.map((a) => a.canonicalAssetId)).size, 2891);
  assert.equal(REGISTRY.assets.filter((a) => a.kind === "native").length, 1);
});

test("run times: every 18 hours", () => {
  const key = (ms, every = 18) => runKeyFor(slotFor(ms, every, ANCHOR));
  assert.equal(key(Date.UTC(2026, 10, 10, 0, 1)), "2026-11-10T00Z");
  assert.equal(key(Date.UTC(2026, 10, 10, 17, 59)), "2026-11-10T00Z");
  assert.equal(key(Date.UTC(2026, 10, 10, 18, 0)), "2026-11-10T18Z");
  assert.equal(key(Date.UTC(2026, 10, 11, 12, 0)), "2026-11-11T12Z");
  assert.equal(key(Date.UTC(2026, 10, 12, 6, 0)), "2026-11-12T06Z");
  assert.equal(key(Date.UTC(2026, 10, 9, 23, 0)), "2026-11-09T06Z", "times before the anchor work too");
  assert.equal(key(Date.UTC(2026, 10, 11, 5, 0), 24), "2026-11-11T00Z");
  let runs = 0;
  for (let ms = ANCHOR; ms < ANCHOR + 30 * 24 * H; ms += H) if (slotFor(ms, 18, ANCHOR) === ms) runs++;
  assert.equal(runs, 40, "40 runs in 30 days");
});

test("switched off: nothing is read, fetched or sent", async () => {
  const ctx = makeDeps({ registry: tinyRegistry(5), start: T0, cfg: { enabled: false } });
  assert.deepEqual(await tick(ctx.deps), { did: "off" });
  assert.equal(ctx.http.calls.length, 0);
  assert.equal(ctx.store.db.state, null);
});

test("watch mode, full registry: every asset is priced once, fetches are spaced, nothing is sent", async () => {
  const ctx = makeDeps({ registry: REGISTRY, start: T0 });
  priceAll(ctx, REGISTRY);
  const seen = await runToEnd(ctx);
  const end = seen.at(-1);
  assert.equal(end.status, "complete");
  const withId = REGISTRY.assets.filter((a) => a.pricingIdentifier).length;
  assert.equal(end.priced, withId);
  assert.equal(end.priced + end.already_unavailable, 2891);
  assert.equal(end.marked_unavailable, 0);
  assert.equal(ctx.chain.sent.length, 0);
  const cg = ctx.http.calls.filter((c) => c.url.includes("coingecko"));
  assert.equal(cg.length, Math.ceil(2891 / 120));
  for (let i = 1; i < cg.length; i++) assert.ok(cg[i].at - cg[i - 1].at >= DEFAULTS.minSpacingMs, "CoinGecko calls are at least 4 minutes apart");
  assert.equal(new Set(ctx.http.cgIdsSeen).size, new Set(REGISTRY.assets.map((a) => a.pricingIdentifier).filter(Boolean)).size);
  assert.ok(cg.every((c) => c.url.split("ids=")[1].split("&")[0].split("%2C").length <= 120));
  const run = ctx.store.db.runs[0];
  assert.equal(run.mode, "watch");
  assert.ok(run.finished_at - run.started_at < 3 * 3600000, "a run takes under three hours");
  assert.equal(ctx.alerts.length, 0);
  // The same slot does not run twice.
  ctx.clock.advance(5 * MIN);
  assert.deepEqual(await tick(ctx.deps), { did: "idle" });
});

test("posting mode: prices are written in order, read back, and the next slot starts a new run", async () => {
  const registry = tinyRegistry(250);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry, "0.5");
  const end = (await runToEnd(ctx)).at(-1);
  assert.equal(end.status, "complete");
  assert.equal(end.priced, 250);
  assert.equal(end.transactions, 3);
  assert.deepEqual(ctx.chain.mined.map((m) => m.runId), [2n, 3n, 4n]);
  assert.deepEqual(ctx.chain.mined.map((m) => m.lines), [120, 120, 10]);
  for (const a of registry.assets) assert.deepEqual(ctx.chain.get(keyOf(a)), { priceUsd30: toUsd30("0.5"), usable: true });
  assert.equal(ctx.chain.sent.length, 3);
  ctx.clock.set(Date.UTC(2026, 10, 10, 12, 2));
  assert.deepEqual(await tick(ctx.deps), { did: "idle" }, "12 hours on, no new run yet");
  ctx.clock.set(Date.UTC(2026, 10, 10, 18, 2));
  priceAll(ctx, registry, "0.75");
  const end2 = (await runToEnd(ctx)).at(-1);
  assert.equal(end2.runKey, "2026-11-10T18Z");
  assert.equal(ctx.chain.last, 7n);
  assert.equal(ctx.chain.get(keyOf(registry.assets[0])).priceUsd30, toUsd30("0.75"));
});

test("an asset that loses its price is marked unavailable; one that never had a price is left alone", async () => {
  const registry = tinyRegistry(4);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  delete ctx.http.cg["coin-1"];
  delete ctx.http.cg["coin-2"];
  ctx.chain.prices.set(keyOf(registry.assets[1]), { priceUsd30: toUsd30("9"), usable: true });
  const end = (await runToEnd(ctx)).at(-1);
  assert.equal(end.priced, 2);
  assert.equal(end.marked_unavailable, 1);
  assert.equal(end.already_unavailable, 1);
  assert.deepEqual(ctx.chain.get(keyOf(registry.assets[1])), { priceUsd30: 0n, usable: false });
  assert.equal(ctx.chain.mined[0].lines, 3);
  assert.equal(ctx.alerts.length, 1);
  assert.match(ctx.alerts[0].subject, /missing prices/);
});

test("no substitute price: a missing, zero or unreadable price is never written as a price", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  ctx.http.cg = { "coin-0": 0, "coin-1": "abc" };
  for (const a of registry.assets) ctx.chain.prices.set(keyOf(a), { priceUsd30: toUsd30("1"), usable: true });
  await runToEnd(ctx);
  for (const a of registry.assets) assert.deepEqual(ctx.chain.get(keyOf(a)), { priceUsd30: 0n, usable: false });
});

test("CoinGecko down: the group is tried again, and prices on chain are untouched until it answers", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry, "2");
  for (const a of registry.assets) ctx.chain.prices.set(keyOf(a), { priceUsd30: toUsd30("1"), usable: true });
  ctx.http.cgDown = true;
  let ticks = 0;
  const end = (await runToEnd(ctx, { each: async (r) => { ticks++; if (ticks === 6) ctx.http.cgDown = false; if (ticks < 6 && r.did !== "started") assert.equal(r.did, "retry-later"); } })).at(-1);
  assert.equal(end.status, "complete");
  assert.equal(end.priced, 3);
  assert.equal(ctx.chain.sent.length, 1);
  assert.equal(ctx.chain.get(keyOf(registry.assets[0])).priceUsd30, toUsd30("2"));
  assert.equal(ctx.http.calls.filter((c) => c.url.includes("dexscreener")).length, 0, "DexScreener is not asked while CoinGecko is being retried");
});

test("CoinGecko down past the deadline: DexScreener is the fallback, and what is still missing is marked unavailable", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  for (const a of registry.assets) ctx.chain.prices.set(keyOf(a), { priceUsd30: toUsd30("1"), usable: true });
  const a0 = registry.assets[0].identifier;
  ctx.http.dex[a0.toLowerCase()] = [{ chainId: "base", pairAddress: "0xpool", baseToken: { address: a0 }, quoteToken: { address: "0xq" }, priceUsd: "3.5", liquidity: { usd: 1000 } }];
  ctx.http.cgDown = true;
  const end = (await runToEnd(ctx)).at(-1);
  const run = ctx.store.db.runs[0];
  assert.ok(run.finished_at - run.started_at >= DEFAULTS.runDeadlineMs);
  assert.equal(end.priced, 1);
  assert.equal(end.marked_unavailable, 2);
  assert.deepEqual(ctx.chain.get(keyOf(registry.assets[0])), { priceUsd30: toUsd30("3.5"), usable: true });
  assert.equal(ctx.chain.get(keyOf(registry.assets[1])).usable, false);
  assert.equal(ctx.alerts.length, 1);
});

test("the function stops after saving a transaction but before sending it: the same lines go out once, at the same nonce", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  ctx.chain.behaviour = "throw";
  await tick(ctx.deps); // start
  ctx.clock.advance(5 * MIN);
  assert.equal((await tick(ctx.deps)).did, "send-error");
  const g = ctx.store.db.groups[0];
  assert.equal(g.status, "sending");
  const saved = g.tx_lines;
  ctx.chain.behaviour = "mine";
  ctx.clock.advance(5 * MIN);
  assert.equal((await tick(ctx.deps)).did, "waiting-for-transaction", "it waits before sending again");
  assert.equal(ctx.chain.sent.length, 0);
  ctx.clock.advance(6 * MIN);
  const end = await tick(ctx.deps);
  assert.equal(end.did, "finished");
  assert.equal(ctx.chain.sent.length, 1);
  assert.equal(ctx.chain.sent[0].nonce, 7);
  assert.equal(ctx.chain.sent[0].calldata, codec.encodeRun(2n, JSON.parse(saved)));
  assert.equal(ctx.chain.mined.length, 1);
});

test("a transaction confirms after the function stopped waiting: it is recognised and not sent again", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  ctx.chain.behaviour = "mine-silently";
  await tick(ctx.deps);
  ctx.clock.advance(5 * MIN);
  assert.equal((await tick(ctx.deps)).did, "sent");
  ctx.chain.behaviour = "mine";
  ctx.clock.advance(5 * MIN);
  const end = await tick(ctx.deps);
  assert.equal(end.did, "finished");
  assert.equal(end.status, "complete");
  assert.equal(ctx.chain.sent.length, 1);
  assert.equal(ctx.chain.mined.length, 1);
});

test("a transaction that never confirms is sent again as the same transaction, never a new one", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  ctx.chain.behaviour = "drop";
  await tick(ctx.deps);
  ctx.clock.advance(5 * MIN);
  await tick(ctx.deps);
  priceAll(ctx, registry, "99"); // prices move while it is pending
  ctx.clock.advance(5 * MIN);
  assert.equal((await tick(ctx.deps)).did, "waiting-for-transaction");
  assert.equal(ctx.chain.sent.length, 1);
  ctx.chain.behaviour = "mine";
  ctx.clock.advance(5 * MIN);
  await tick(ctx.deps);
  assert.equal(ctx.chain.sent.length, 2);
  assert.equal(ctx.chain.sent[1].calldata, ctx.chain.sent[0].calldata);
  assert.equal(ctx.chain.sent[1].nonce, ctx.chain.sent[0].nonce);
  assert.equal(ctx.chain.sent[1].bump, 1);
  assert.equal(ctx.chain.mined.length, 1);
  assert.equal(ctx.chain.get(keyOf(registry.assets[0])).priceUsd30, toUsd30("1.25"));
});

test("a reverted transaction: the group is priced again with a fresh run number", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  ctx.chain.behaviour = "revert";
  await tick(ctx.deps);
  ctx.clock.advance(5 * MIN);
  assert.equal((await tick(ctx.deps)).did, "reverted");
  ctx.chain.behaviour = "mine";
  const end = (await runToEnd(ctx)).at(-1);
  assert.equal(end.status, "complete");
  assert.equal(ctx.chain.mined.length, 1);
  assert.equal(ctx.chain.mined[0].nonce, 8);
});

test("two calls at once: the second does nothing", async () => {
  const ctx = makeDeps({ registry: tinyRegistry(3), start: T0 });
  const state = await ctx.store.loadState();
  await ctx.store.claim(state, "someone-else", ctx.clock.now(), DEFAULTS.leaseMs);
  assert.deepEqual(await tick(ctx.deps), { did: "busy" });
  ctx.clock.advance(DEFAULTS.leaseMs + 1);
  assert.equal((await tick(ctx.deps)).did, "started", "a lock left by a call that died is taken over after it expires");
});

test("no key, wrong key, low balance, high cost: nothing is sent and the team is told once", async () => {
  for (const [setup, kind] of [
    [(c) => { c.signer = null; }, /no poster key/],
    [(c) => { c.signer = "0x000000000000000000000000000000000000dEaD"; }, /does not belong/],
    [(c) => { c.balanceWei = 1n; }, /enough ETH/],
    [(c) => { c.costWei = 10n ** 18n; }, /above the limit/],
  ]) {
    const registry = tinyRegistry(3);
    const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
    priceAll(ctx, registry);
    setup(ctx.chain);
    await tick(ctx.deps);
    for (let i = 0; i < 3; i++) { ctx.clock.advance(5 * MIN); const r = await tick(ctx.deps); assert.equal(r.did, "held"); assert.match(r.reason, kind); }
    assert.equal(ctx.chain.sent.length, 0);
    assert.equal(ctx.alerts.length, 1);
  }
});

test("posting switched off during a run: the rest of the run sends nothing", async () => {
  const registry = tinyRegistry(250);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  await tick(ctx.deps);
  ctx.clock.advance(5 * MIN);
  await tick(ctx.deps);
  assert.equal(ctx.chain.sent.length, 1);
  ctx.deps.cfg.posting = false;
  await runToEnd(ctx);
  assert.equal(ctx.chain.sent.length, 1);
});

test("a run that cannot finish is closed at the hard stop and reported, and the next run still starts", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  ctx.chain.signer = null;
  const end = (await runToEnd(ctx)).at(-1);
  assert.equal(end.status, "incomplete");
  assert.ok(ctx.alerts.some((a) => /did not finish/.test(a.subject)));
  ctx.chain.signer = POSTER;
  ctx.clock.set(Date.UTC(2026, 10, 10, 18, 1));
  assert.equal((await tick(ctx.deps)).did, "started");
});

test("a run time that passes with nothing started is reported once", async () => {
  const ctx = makeDeps({ registry: tinyRegistry(3), start: Date.UTC(2026, 10, 9, 20, 0) });
  await tick(ctx.deps); // creates the saved state; too late for the run time before it
  ctx.store.db.state.created_at_ms = Date.UTC(2026, 10, 9, 20, 0);
  ctx.clock.set(Date.UTC(2026, 10, 10, 3, 0));
  await tick(ctx.deps);
  await tick(ctx.deps);
  assert.equal(ctx.alerts.filter((a) => /missed/.test(a.subject)).length, 1);
});

test("DexScreener: Base pools only, most liquidity wins; row 138 alone may use another chain", async () => {
  const clock = { now: () => 0, sleep: async () => {} };
  const tok = "0x00000000000000000000000000000000000000AA";
  const cross = "0xCF7Fc0De71238c9EC45EC2Fd24FDc8521345dbB5";
  const pair = (chainId, addr, price, liq, pairAddress) => ({ chainId, pairAddress, baseToken: { address: addr }, quoteToken: { address: "0xq" }, priceUsd: price, liquidity: { usd: liq } });
  const urls = [];
  const http = async (url) => {
    urls.push(url);
    if (url.includes("/token-pairs/v1/base/" + tok)) return { status: 200, body: JSON.stringify([pair("base", tok, "1", 10, "0xa"), pair("base", tok, "2", 500, "0xb"), pair("bsc", tok, "7", 9e9, "0xc")]) };
    if (url.includes("/token-pairs/v1/base/" + cross)) return { status: 200, body: "[]" };
    if (url.includes("/latest/dex/tokens/" + cross)) return { status: 200, body: JSON.stringify({ pairs: [pair("bsc", cross, "0.004", 100, "0xd")] }) };
    return { status: 200, body: "{}" };
  };
  const rows = [
    { row: 1, symbol: "A", canonicalAssetId: ethers.id("a"), identifier: tok, kind: "token", pricingIdentifier: null },
    { row: 138, symbol: "B", canonicalAssetId: ethers.id("b"), identifier: cross, kind: "token", pricingIdentifier: null },
  ];
  const { results } = await fetchGroup(rows, { http, ...clock });
  assert.equal(results[0].usd, "2");
  assert.equal(results[1].usd, "0.004");
  assert.equal(urls.filter((u) => u.includes("/latest/dex/tokens/")).length, 1);
  assert.ok(!urls.some((u) => u.includes("search")), "no lookup by symbol");
});

test("DexScreener says too many requests twice, then answers: the asset is still priced", async () => {
  let t = 0;
  const clock = { now: () => t, sleep: async (ms) => { t += ms; } };
  const tok = "0x00000000000000000000000000000000000000BB";
  let n = 0;
  const http = async () => (++n < 3 ? { status: 429, body: "" } : { status: 200, body: JSON.stringify([{ chainId: "base", pairAddress: "0xa", baseToken: { address: tok }, quoteToken: { address: "0xq" }, priceUsd: "0.02", liquidity: { usd: 5 } }]) });
  const rows = [{ row: 9, symbol: "C", canonicalAssetId: ethers.id("c"), identifier: tok, kind: "token", pricingIdentifier: null }];
  const { results } = await fetchGroup(rows, { http, ...clock });
  assert.equal(results[0].usd, "0.02");
  assert.equal(n, 3);
  assert.ok(t >= 12000, "it waited 4 and then 8 seconds");
});

const pool = (addr, price) => [{ chainId: "base", pairAddress: "0xpool", baseToken: { address: addr }, quoteToken: { address: "0xq" }, priceUsd: price, liquidity: { usd: 1000 } }];

test("a service that is busy for one asset: nothing is written for it until it has been tried again", async () => {
  const registry = tinyRegistry(4);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry, "2");
  const a = registry.assets[1];
  delete ctx.http.cg[a.pricingIdentifier];
  ctx.http.dex[a.identifier.toLowerCase()] = pool(a.identifier, "7");
  ctx.http.dexBusy[a.identifier.toLowerCase()] = 5; // 3 tries in the group, 2 more in the first retry
  ctx.chain.prices.set(keyOf(a), { priceUsd30: toUsd30("6"), usable: true });
  let afterGroup = null;
  const end = (await runToEnd(ctx, { each: async (r) => { if (r.did === "posted" && afterGroup === null) afterGroup = { ...ctx.chain.get(keyOf(a)) }; } })).at(-1);
  assert.deepEqual(afterGroup, { priceUsd30: toUsd30("6"), usable: true }, "its old price is untouched after the group's transaction");
  assert.equal(ctx.chain.mined[0].lines, 3);
  assert.equal(end.status, "complete");
  assert.deepEqual(ctx.chain.get(keyOf(a)), { priceUsd30: toUsd30("7"), usable: true });
  assert.equal(end.priced, 4);
  assert.equal(end.marked_unavailable, 0);
  assert.equal(end.fetch_errors, 0);
  assert.equal(ctx.store.db.runs[0].retried, 1);
  assert.equal(ctx.chain.mined.length, 2);
  assert.equal(ctx.alerts.length, 0);
});

test("a service that never answers for an asset: after the further tries it is marked unavailable", async () => {
  const registry = tinyRegistry(4);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry, "2");
  const a = registry.assets[1];
  delete ctx.http.cg[a.pricingIdentifier];
  ctx.http.dexBusy[a.identifier.toLowerCase()] = 1e9;
  ctx.chain.prices.set(keyOf(a), { priceUsd30: toUsd30("6"), usable: true });
  const end = (await runToEnd(ctx)).at(-1);
  assert.equal(end.status, "complete");
  assert.deepEqual(ctx.chain.get(keyOf(a)), { priceUsd30: 0n, usable: false });
  assert.equal(end.priced, 3);
  assert.equal(end.marked_unavailable, 1);
  assert.equal(end.fetch_errors, 1);
  const run = ctx.store.db.runs[0];
  assert.ok(run.finished_at - run.started_at < DEFAULTS.runDeadlineMs, "it does not wait for the deadline");
  assert.equal(ctx.store.db.groups.find((g) => g.kind === "retry").retry_queue[0].tries, DEFAULTS.retryMaxTries);
  assert.equal(ctx.alerts.length, 1);
});

test("many assets to try again: they are worked through a few per call, and every asset is counted once", async () => {
  const registry = tinyRegistry(40);
  const ctx = makeDeps({ registry, start: T0 });
  priceAll(ctx, registry, "2");
  const last = registry.assets[19];
  ctx.chain.prices.set(keyOf(last), { priceUsd30: toUsd30("1"), usable: true });
  for (const a of registry.assets.slice(0, 20)) {
    delete ctx.http.cg[a.pricingIdentifier];
    ctx.http.dex[a.identifier.toLowerCase()] = pool(a.identifier, "3");
    ctx.http.dexBusy[a.identifier.toLowerCase()] = 4;
  }
  ctx.http.dexBusy[last.identifier.toLowerCase()] = 0; // the first pass runs out of time before reaching it
  const seen = await runToEnd(ctx);
  const end = seen.at(-1);
  assert.equal(end.status, "complete");
  assert.equal(end.priced, 40);
  assert.equal(end.priced + end.marked_unavailable + end.already_unavailable, 40);
  assert.equal(ctx.store.db.runs[0].retried, 20);
  assert.ok(seen.filter((r) => r.did === "retry-later").length >= 3);
  const retry = ctx.store.db.groups.find((g) => g.kind === "retry");
  assert.equal(retry.retry_found.length, 20);
  assert.equal(retry.retry_found[0].row, last.row, "the asset with a usable price on chain is tried first");
  assert.equal(ctx.chain.sent.length, 0);
});

test("the CoinGecko Demo key is sent as its header and never put in the address", async () => {
  const ctx = makeDeps({ registry: tinyRegistry(2), start: T0, cfg: { coingeckoKey: "CG-secret" } });
  priceAll(ctx, ctx.deps.registry);
  await runToEnd(ctx);
  const cg = ctx.http.calls.filter((c) => c.url.includes("coingecko"));
  assert.ok(cg.length > 0 && cg.every((c) => c.headers["x-cg-demo-api-key"] === "CG-secret" && !c.url.includes("CG-secret")));
});

test("website status: no addresses, and a late-prices flag only when posting is on", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0, cfg: { posting: true } });
  priceAll(ctx, registry);
  assert.equal((await publicStatus(ctx.deps)).pricesAreLate, true);
  await runToEnd(ctx);
  let s = await publicStatus(ctx.deps);
  assert.equal(s.pricesAreLate, false);
  assert.equal(s.lastPostedRun.priced, 3);
  assert.ok(!/0x[0-9a-fA-F]{40}/.test(JSON.stringify(s)));
  ctx.clock.advance(16 * H);
  assert.equal((await publicStatus(ctx.deps)).pricesAreLate, false);
  ctx.clock.advance(6 * H);
  s = await publicStatus(ctx.deps);
  assert.equal(s.pricesAreLate, true);
  assert.equal(s.intervalHours, 18);
  ctx.deps.cfg.posting = false;
  assert.equal((await publicStatus(ctx.deps)).pricesAreLate, null);
});

test("old per-group detail is removed after 14 days; run summaries stay", async () => {
  const registry = tinyRegistry(3);
  const ctx = makeDeps({ registry, start: T0 });
  priceAll(ctx, registry);
  await runToEnd(ctx);
  assert.equal(ctx.store.db.groups.length, 1);
  ctx.clock.set(T0 + 15 * 86400000);
  await runToEnd(ctx);
  assert.equal(ctx.store.db.runs.length, 2);
  assert.equal(ctx.store.db.groups.filter((g) => g.run_key === "2026-11-10T00Z").length, 0);
  assert.equal(ctx.store.db.runs[0].detail_removed, true);
});
