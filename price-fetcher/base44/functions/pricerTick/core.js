// Vinculum price fetcher: the run logic.
//
// A run prices every asset in the Base registry once. A new run starts every
// 18 hours. Each call of tick() does one small piece of the run, saves
// where it got to, and stops. A group of assets is priced, and in posting
// mode that group's prices are written to the Base Verifier straight away in
// one transaction. Calls are spaced out, so a run takes about three hours.
//
// When a price service fails to answer for an asset, that asset is left out
// of its group and nothing is written for it. After all groups are done,
// those assets are tried again, a few at a time and slowly. Only at the end
// of that is an asset with no price marked unavailable.
//
// Nothing in this file talks to the outside world directly. The saved state,
// the price services, the chain and the clock are passed in, so the same
// logic runs in production and in the tests.

import { fetchGroup, planLines, linesOf } from "./prices.js";

export const VERSION = "1.3";

export const DEFAULTS = Object.freeze({
  enabled: false, // master switch
  posting: false, // false: fetch and record only, never sign or send
  intervalHours: 18, // a new run starts this often
  anchorMs: Date.UTC(2026, 10, 10, 0, 0), // run times are counted from here (Nov 10, 2026, 00:00 UTC)
  groupSize: 120, // assets per group, and lines per transaction
  minSpacingMs: 4 * 60 * 1000, // least time between two price fetches
  startWindowMs: 2 * 60 * 60 * 1000, // a run may start this long after its time
  runDeadlineMs: 6 * 60 * 60 * 1000, // after this, a group is no longer tried again
  hardStopMs: 10 * 60 * 60 * 1000, // after this, the run is closed whatever its state
  retryBatch: 6, // assets tried again in one call
  retryDexPauseMs: 12000, // pause between DexScreener lookups when trying again
  retryMaxTries: 6, // further tries for an asset before it counts as having no price
  fetchBudgetMs: 120 * 1000, // time one call may spend fetching
  receiptWaitMs: 45 * 1000, // time one call waits for a transaction to confirm
  pendingWaitMs: 10 * 60 * 1000, // wait before sending an unconfirmed transaction again
  maxResends: 3,
  maxReadbackChecks: 3,
  leaseMs: 6 * 60 * 1000, // longer than the longest a call can run
  maxTxCostWei: 300000000000000n, // 0.0003 ETH for one transaction
  minRunId: 2n,
  keepDetailDays: 14,
});

const DONE = new Set(["watched", "posted", "nothing_to_post", "failed"]);
const GOOD = new Set(["watched", "posted", "nothing_to_post"]);

// Start time of the most recent run slot at or before nowMs. Slots are a
// fixed number of hours apart, counted from the anchor.
export function slotFor(nowMs, intervalHours, anchorMs) {
  const step = intervalHours * 3600000;
  return anchorMs + Math.floor((nowMs - anchorMs) / step) * step;
}

export function runKeyFor(slotMs) {
  return new Date(slotMs).toISOString().slice(0, 13) + "Z";
}

export function easternTime(ms) {
  return new Date(ms).toLocaleString("en-US", { timeZone: "America/New_York", dateStyle: "medium", timeStyle: "short" }) + " ET";
}

function groupRows(registry, index, size) {
  return registry.assets.slice(index * size, (index + 1) * size);
}

function assetsByRow(registry) {
  if (!registry._byRow) Object.defineProperty(registry, "_byRow", { value: new Map(registry.assets.map((a) => [a.row, a])) });
  return registry._byRow;
}

function countPlan(plan, results) {
  const n = (a) => plan.filter((p) => p.action === a).length;
  return {
    priced: n("post-price"),
    marked_unavailable: n("post-unavailable"),
    already_unavailable: n("skip-already-unavailable"),
    fetch_errors: results.filter((r) => r.reason === "fetch_error").length,
  };
}

function compactPlan(plan) {
  return plan.map((p) => ({ row: p.row, symbol: p.symbol, action: p.action, usd: p.usd, source: p.source, why: p.why }));
}

const errText = (e) => String((e && (e.shortMessage || e.message)) || e).slice(0, 300);

async function tellTheTeam(deps, run, kind, subject, body) {
  const sent = run.alerts_sent || [];
  if (sent.includes(kind)) return;
  await deps.store.patchRun(run, { alerts_sent: [...sent, kind] });
  try {
    await deps.alert(subject, body);
  } catch (e) {
    deps.log("alert could not be sent: " + errText(e));
  }
}

// One call. Returns a short record of what it did.
export async function tick(deps, { manualStart = false } = {}) {
  const { cfg, store, clock } = deps;
  if (!cfg.enabled) return { did: "off" };
  const state = await store.loadState();
  const token = deps.newToken();
  if (!(await store.claim(state, token, clock.now(), cfg.leaseMs))) return { did: "busy" };
  try {
    return await step(deps, state, manualStart);
  } catch (e) {
    const now = clock.now();
    const patch = { last_error: errText(e), last_error_at: now };
    const tell = now - (state.last_error_alert_at || 0) > 6 * 3600000;
    if (tell) patch.last_error_alert_at = now;
    await store.patchState(state, patch);
    if (tell) {
      try {
        await deps.alert("Vinculum prices: the price fetcher hit an error", "At " + easternTime(now) + " a step of the price fetcher stopped with this error: " + errText(e) + ". It tries again on its next call. Prices already on chain stay as they are.");
      } catch (e2) {
        deps.log("alert could not be sent: " + errText(e2));
      }
    }
    return { did: "error", error: errText(e) };
  } finally {
    await store.release(state, token);
  }
}

async function step(deps, state, manualStart) {
  const { cfg, store, clock, registry } = deps;
  const startedTick = clock.now();
  let run = state.current_run_key ? await store.findRun(state.current_run_key) : null;
  if (run && run.status !== "running") run = null;

  if (!run) {
    const now = clock.now();
    let key;
    if (manualStart) key = "manual-" + new Date(now).toISOString().slice(0, 19) + "Z";
    else {
      const slot = slotFor(now, cfg.intervalHours, cfg.anchorMs);
      key = runKeyFor(slot);
      if (await store.findRun(key)) return { did: "idle" };
      if (now - slot > cfg.startWindowMs) {
        if (state.last_missed_key !== key && (state.created_at_ms || now) < slot) {
          await store.patchState(state, { last_missed_key: key });
          try {
            await deps.alert("Vinculum prices: a run was missed", "The price run for " + easternTime(slot) + " did not start. The last posted prices stay in effect. The next run starts at its normal time.");
          } catch (e) {
            deps.log("alert could not be sent: " + errText(e));
          }
        }
        return { did: "idle" };
      }
    }
    const total = Math.ceil(registry.assets.length / cfg.groupSize);
    run = await store.createRun({
      run_key: key,
      status: "running",
      mode: cfg.posting ? "post" : "watch",
      started_at: now,
      deadline_at: now + cfg.runDeadlineMs,
      groups_total: total,
      assets_total: registry.assets.length,
      alerts_sent: [],
    });
    await store.patchState(state, { current_run_key: key });
    await ensureGroups(deps, run, []);
    return { did: "started", runKey: key };
  }

  let groups = await ensureGroups(deps, run, await store.groupsOf(run.run_key));
  const now = clock.now();
  const hardStop = now > run.started_at + cfg.hardStopMs;

  const inflight = groups.find((g) => g.status === "sending" || g.status === "sent");
  if (inflight) {
    const r = await reconcile(deps, run, inflight);
    if (r.wait && !hardStop) return { did: "waiting-for-transaction", group: inflight.index };
    if (r.wait && hardStop) await store.patchGroup(inflight, { status: "failed", note: "the transaction's outcome was still unknown when the run was closed" });
  }

  let open = groups.filter((g) => g.status === "pending");
  if (hardStop) {
    for (const g of open) await store.patchGroup(g, { status: "failed", note: (g.note ? g.note + "; " : "") + "not finished when the run was closed" });
    open = [];
  }
  if (!open.length && !hardStop && !run.retry_made) {
    await makeRetryGroups(deps, run, groups);
    groups = (await store.groupsOf(run.run_key)).sort((a, b) => a.index - b.index);
    open = groups.filter((g) => g.status === "pending");
  }
  if (!open.length) return await finish(deps, state, run, groups);

  if (now - (state.last_fetch_at || 0) < cfg.minSpacingMs) return { did: "pacing" };
  open.sort((a, b) => (a.attempts || 0) - (b.attempts || 0) || a.index - b.index);
  const group = open[0];
  await store.patchState(state, { last_fetch_at: now });
  const result = await work(deps, run, group, startedTick);

  groups = await store.groupsOf(run.run_key);
  if (run.retry_made && groups.every((g) => DONE.has(g.status))) return await finish(deps, state, run, groups);
  return result;
}

// Assets a price service did not answer for are collected into extra groups
// that are worked on after all the others.
async function makeRetryGroups(deps, run, groups) {
  const { store, cfg } = deps;
  let rows = groups.filter((g) => g.kind !== "retry").flatMap((g) => g.deferred_rows || []);
  if (rows.length) {
    // Assets that have a usable price on chain now go first: they are the
    // ones a missing answer would change.
    const byRow = assetsByRow(deps.registry);
    const keys = rows.map((row) => deps.codec.assetKey(byRow.get(row).canonicalAssetId));
    const onchain = await deps.chain.readPrices(keys);
    const usable = new Set(rows.filter((row, i) => onchain.get(keys[i]).usable));
    rows = [...rows.filter((row) => usable.has(row)), ...rows.filter((row) => !usable.has(row))];
  }
  const have = new Set(groups.filter((g) => g.kind === "retry").map((g) => g.index));
  let made = 0;
  for (let i = 0; i < rows.length; i += cfg.groupSize) {
    const index = run.groups_total + made++;
    if (have.has(index)) continue;
    await store.createGroup({
      run_key: run.run_key,
      index,
      kind: "retry",
      status: "pending",
      attempts: 0,
      retry_queue: rows.slice(i, i + cfg.groupSize).map((row) => ({ row, tries: 0 })),
      retry_found: [],
    });
  }
  await store.patchRun(run, { retry_made: true, retry_groups: made, retried: rows.length });
}

// One call's worth of trying again. Returns the final results once every
// asset in the group has a price, a definite "no price", or is out of tries.
async function gatherRetry(deps, run, group, startedTick, pastDeadline) {
  const { cfg, store, clock, registry } = deps;
  const byRow = assetsByRow(registry);
  let queue = group.retry_queue || [];
  let found = group.retry_found || [];
  const live = queue.filter((q) => q.tries < cfg.retryMaxTries);
  if (live.length && !pastDeadline) {
    const batch = live.slice(0, cfg.retryBatch);
    const { results } = await fetchGroup(batch.map((q) => byRow.get(q.row)), {
      http: deps.http,
      sleep: clock.sleep,
      now: clock.now,
      cgKey: cfg.coingeckoKey || "",
      budgetEndsAt: startedTick + cfg.fetchBudgetMs,
      dexPauseMs: cfg.retryDexPauseMs,
    });
    const settled = results.filter((x) => x.reason !== "fetch_error");
    const failed = new Map(results.filter((x) => x.reason === "fetch_error").map((x) => [x.row, x]));
    const tried = new Set(batch.map((q) => q.row));
    queue = [...queue.filter((q) => !tried.has(q.row)), ...batch.filter((q) => failed.has(q.row)).map((q) => {
      const f = failed.get(q.row);
      // An asset the call ran out of time for was not tried, so it does not use up a try.
      return f.notTried ? q : { row: q.row, tries: q.tries + 1, why: f.detail };
    })];
    found = [...found, ...settled];
    const left = queue.filter((q) => q.tries < cfg.retryMaxTries).length;
    await store.patchGroup(group, { retry_queue: queue, retry_found: found, attempts: (group.attempts || 0) + 1, note: left + " asset(s) still to be tried again" });
    if (left) return { ready: false, out: { did: "retry-later", group: group.index, note: left + " asset(s) still to be tried again" } };
  }
  const gaveUp = queue.map((q) => {
    const a = byRow.get(q.row);
    return { row: a.row, symbol: a.symbol, canonicalAssetId: a.canonicalAssetId, usd: null, source: null, reason: "fetch_error", detail: q.why || "the price services did not answer" };
  });
  return { ready: true, results: [...found, ...gaveUp] };
}

async function ensureGroups(deps, run, groups) {
  const have = new Set(groups.map((g) => g.index));
  let added = false;
  for (let i = 0; i < run.groups_total; i++) {
    if (have.has(i)) continue;
    await deps.store.createGroup({ run_key: run.run_key, index: i, status: "pending", attempts: 0 });
    added = true;
  }
  const all = added ? await deps.store.groupsOf(run.run_key) : groups;
  return all.sort((a, b) => a.index - b.index);
}

// Price one group, and in posting mode write it to the Verifier.
async function work(deps, run, group, startedTick) {
  const { cfg, store, clock, registry, chain, codec } = deps;
  const pastDeadline = clock.now() > run.deadline_at;
  let attempts = (group.attempts || 0) + 1;
  let results;
  let deferred = [];

  if (group.kind === "retry") {
    const g = await gatherRetry(deps, run, group, startedTick, pastDeadline);
    if (!g.ready) return g.out;
    results = g.results;
    attempts = group.attempts || attempts;
  } else {
    const fetched = await fetchGroup(groupRows(registry, group.index, cfg.groupSize), {
      http: deps.http,
      sleep: clock.sleep,
      now: clock.now,
      cgKey: cfg.coingeckoKey || "",
      budgetEndsAt: startedTick + cfg.fetchBudgetMs,
      dexAfterCgFailure: pastDeadline,
    });
    if (fetched.cgError && !pastDeadline) {
      const note = "CoinGecko did not answer (" + fetched.cgError + "); will try again";
      await store.patchGroup(group, { attempts, note });
      return { did: "retry-later", group: group.index, note };
    }
    results = fetched.results;
    // Before the deadline, an asset a service failed to answer for is set
    // aside to be tried again later. Nothing is written for it now.
    if (!pastDeadline) {
      deferred = results.filter((x) => x.reason === "fetch_error").map((x) => x.row);
      results = results.filter((x) => x.reason !== "fetch_error");
    }
  }

  const keys = results.map((x) => codec.assetKey(x.canonicalAssetId));
  const onchain = await chain.readPrices(keys);
  const plan = planLines(results, onchain, codec.assetKey);
  const counts = { ...countPlan(plan, results), deferred_rows: deferred, deferred_count: deferred.length };
  const detail = compactPlan(plan);
  const lines = linesOf(plan);

  if (run.mode !== "post" || !cfg.posting) {
    await store.patchGroup(group, { status: "watched", attempts, results: detail, ...counts, note: lines.length + " line(s) would be written; nothing was sent" });
    return { did: "watched", group: group.index, lines: lines.length };
  }
  if (!lines.length) {
    await store.patchGroup(group, { status: "nothing_to_post", attempts, results: detail, ...counts, note: "no line to write" });
    return { did: "nothing-to-post", group: group.index };
  }

  const hold = async (kind, reason) => {
    await store.patchGroup(group, { status: pastDeadline ? "failed" : "pending", attempts, results: detail, ...counts, note: reason });
    await tellTheTeam(deps, run, kind, "Vinculum prices: posting is held", "The price run that started " + easternTime(run.started_at) + " could not post a group of prices. Reason: " + reason + ". Prices already on chain stay as they are. The run keeps trying until its deadline.");
    return { did: "held", group: group.index, reason };
  };

  const poster = await chain.poster();
  const signer = chain.signerAddress();
  if (!signer) return hold("no-key", "no poster key is set");
  if (signer.toLowerCase() !== poster.toLowerCase()) return hold("wrong-key", "the key that is set does not belong to the poster the Verifier accepts");
  const last = await chain.lastRunId();
  const runId = last + 1n > cfg.minRunId ? last + 1n : cfg.minRunId;
  const calldata = codec.encodeRun(runId, lines);
  try {
    await chain.simulate(calldata, poster);
  } catch (e) {
    return hold("simulation", "the Verifier would reject the transaction (" + errText(e) + ")");
  }
  const est = await chain.estimate(calldata, poster);
  if (est.costWei > cfg.maxTxCostWei) return hold("cost", "the estimated cost of one transaction is above the limit");
  const balance = await chain.balance(poster);
  if (balance < est.costWei * 2n) return hold("balance", "the poster wallet does not hold enough ETH for gas");
  const nonce = await chain.nonce(poster, "latest");

  // Save what is about to be sent before sending it.
  await store.patchGroup(group, {
    status: "sending",
    attempts,
    results: detail,
    ...counts,
    note: "",
    tx_run_id: runId.toString(),
    tx_nonce: nonce,
    tx_payload_hash: codec.hash(calldata),
    tx_lines: JSON.stringify(lines),
    tx_gas_limit: est.gasLimit.toString(),
    tx_sent_at: clock.now(),
    tx_hash: "",
    tx_resends: 0,
    tx_checks: 0,
  });
  return await broadcast(deps, run, group, calldata, nonce, est.gasLimit, 0);
}

async function broadcast(deps, run, group, calldata, nonce, gasLimit, bump) {
  const { cfg, store, chain } = deps;
  let hash;
  try {
    hash = await chain.send({ calldata, nonce, gasLimit, bump });
  } catch (e) {
    await store.patchGroup(group, { note: "sending failed (" + errText(e) + "); will be checked on the next call" });
    return { did: "send-error", group: group.index };
  }
  await store.patchGroup(group, { status: "sent", tx_hash: hash });
  const receipt = await chain.waitReceipt(hash, cfg.receiptWaitMs);
  if (!receipt) return { did: "sent", group: group.index, hash };
  if (receipt.status !== 1) {
    await backToPending(deps, group, "the transaction was reverted on chain");
    return { did: "reverted", group: group.index, hash };
  }
  return await readBack(deps, group, receipt.blockNumber);
}

async function backToPending(deps, group, note) {
  await deps.store.patchGroup(group, { status: "pending", note, tx_hash: "", tx_lines: "", tx_run_id: "", tx_payload_hash: "" });
}

// After a transaction: read the Verifier and compare with what was sent.
async function readBack(deps, group, blockTag) {
  const { cfg, store, chain, codec } = deps;
  const lines = JSON.parse(group.tx_lines);
  const keys = lines.map((l) => codec.assetKey(l.canonicalAssetId));
  const onchain = await chain.readPrices(keys, blockTag);
  let bad = 0;
  lines.forEach((l, i) => {
    const cur = onchain.get(keys[i]);
    const ok = cur && cur.usable === l.success && (!l.success || cur.priceUsd30 === BigInt(l.priceUsd30));
    if (!ok) bad++;
  });
  if (!bad) {
    await store.patchGroup(group, { status: "posted", note: lines.length + " line(s) written and read back" });
    return { did: "posted", group: group.index, lines: lines.length, wait: false };
  }
  const checks = (group.tx_checks || 0) + 1;
  if (checks >= cfg.maxReadbackChecks) {
    await backToPending(deps, group, "the Verifier did not show what was sent; the group will be priced again");
    return { did: "readback-mismatch", group: group.index, wait: false };
  }
  await store.patchGroup(group, { tx_checks: checks, note: bad + " line(s) not yet visible on chain; checking again" });
  return { did: "readback-waiting", group: group.index, wait: true };
}

// A transaction was saved or sent by an earlier call. Find out what became of
// it. A missing receipt alone is never a reason to sign something new: the
// only thing ever sent again is the same saved lines, at the same nonce, so
// at most one of them can be included.
async function reconcile(deps, run, group) {
  const { cfg, store, chain, codec, clock } = deps;
  const runId = BigInt(group.tx_run_id);
  if ((await chain.lastRunId()) >= runId) return await readBack(deps, group);
  if (group.tx_hash) {
    const receipt = await chain.receipt(group.tx_hash);
    if (receipt && receipt.status !== 1) {
      await backToPending(deps, group, "the transaction was reverted on chain");
      return { wait: false };
    }
    if (receipt) return { wait: true };
  }
  const poster = await chain.poster();
  if ((await chain.nonce(poster, "latest")) > group.tx_nonce) {
    if ((await chain.lastRunId()) >= runId) return await readBack(deps, group);
    await backToPending(deps, group, "the poster's transaction slot was used by a different transaction; the group will be priced again");
    return { wait: false };
  }
  if (clock.now() - group.tx_sent_at < cfg.pendingWaitMs) return { wait: true };
  if (!cfg.posting || (group.tx_resends || 0) >= cfg.maxResends) {
    await tellTheTeam(deps, run, "stuck", "Vinculum prices: a transaction is not confirming", "A price transaction sent in the run that started " + easternTime(run.started_at) + " has not confirmed. Prices already on chain stay as they are.");
    return { wait: true };
  }
  const lines = JSON.parse(group.tx_lines);
  const calldata = codec.encodeRun(runId, lines);
  if (codec.hash(calldata) !== group.tx_payload_hash) throw new Error("saved transaction does not match its fingerprint");
  const resends = (group.tx_resends || 0) + 1;
  await store.patchGroup(group, { tx_resends: resends, tx_sent_at: clock.now(), status: "sending" });
  const r = await broadcast(deps, run, group, calldata, group.tx_nonce, BigInt(group.tx_gas_limit), resends);
  return { wait: r.did !== "posted" && r.did !== "reverted" && r.did !== "readback-mismatch" };
}

async function finish(deps, state, run, groupsIn) {
  const { store, clock } = deps;
  const groups = await store.groupsOf(run.run_key);
  const sum = (f) => groups.reduce((n, g) => n + (g[f] || 0), 0);
  const complete = Boolean(run.retry_made) && groups.length === run.groups_total + (run.retry_groups || 0) && groups.every((g) => GOOD.has(g.status));
  const now = clock.now();
  const totals = {
    status: complete ? "complete" : "incomplete",
    finished_at: now,
    groups_done: groups.filter((g) => GOOD.has(g.status)).length,
    priced: sum("priced"),
    marked_unavailable: sum("marked_unavailable"),
    already_unavailable: sum("already_unavailable"),
    fetch_errors: sum("fetch_errors"),
    transactions: groups.filter((g) => g.status === "posted").length,
  };
  await store.patchRun(run, totals);
  await store.patchState(state, { current_run_key: "" });

  const lines = [
    "Run started " + easternTime(run.started_at) + ", finished " + easternTime(now) + ".",
    "Mode: " + (run.mode === "post" ? "posting" : "watch only, nothing sent") + ".",
    "Assets priced: " + totals.priced + " of " + run.assets_total + ".",
    "Assets newly marked unavailable: " + totals.marked_unavailable + ".",
    "Assets with no price that were already unavailable: " + totals.already_unavailable + ".",
    "Assets that needed another try because a price service did not answer: " + (run.retried || 0) + ".",
    "Of those, assets still without an answer at the end: " + totals.fetch_errors + ".",
    "Groups finished: " + totals.groups_done + " of " + groups.length + ".",
  ];
  if (!complete) await tellTheTeam(deps, run, "incomplete", "Vinculum prices: a run did not finish", lines.join("\n"));
  else if (totals.marked_unavailable > 0 || totals.fetch_errors > 0) await tellTheTeam(deps, run, "attention", "Vinculum prices: a run finished with missing prices", lines.join("\n"));

  await prune(deps, now);
  return { did: "finished", runKey: run.run_key, ...totals };
}

// Per-group detail is kept for a limited time. The run summaries are kept.
async function prune(deps, now) {
  const { store, cfg } = deps;
  const old = (await store.recentRuns(60)).find((r) => r.status !== "running" && !r.detail_removed && now - (r.finished_at || r.started_at) > cfg.keepDetailDays * 86400000);
  if (!old) return;
  for (const g of await store.groupsOf(old.run_key)) await store.deleteGroup(g);
  await store.patchRun(old, { detail_removed: true });
}

// What the website may show. No addresses, no keys, no per-asset detail.
export async function publicStatus(deps) {
  const { store, clock, cfg } = deps;
  const runs = await store.recentRuns(10);
  const pick = (r) => r && {
    started: new Date(r.started_at).toISOString(),
    finished: r.finished_at ? new Date(r.finished_at).toISOString() : null,
    status: r.status,
    mode: r.mode,
    assets: r.assets_total,
    priced: r.priced ?? null,
    markedUnavailable: r.marked_unavailable ?? null,
  };
  const finished = runs.filter((r) => r.status !== "running").sort((a, b) => b.started_at - a.started_at);
  const lastPosted = finished.find((r) => r.mode === "post" && r.status === "complete");
  const current = runs.find((r) => r.status === "running");
  const intervalMs = cfg.intervalHours * 3600000;
  const now = clock.now();
  return {
    version: VERSION,
    enabled: cfg.enabled,
    posting: cfg.posting,
    intervalHours: cfg.intervalHours,
    nextRunStarts: new Date(slotFor(now, cfg.intervalHours, cfg.anchorMs) + intervalMs).toISOString(),
    lastRun: pick(finished[0]) || null,
    lastPostedRun: pick(lastPosted) || null,
    currentRun: pick(current) || null,
    // Only meaningful while posting is on: no finished posting run within one
    // interval plus the time a run takes.
    pricesAreLate: cfg.posting ? !lastPosted || now - lastPosted.finished_at > intervalMs + 3 * 3600000 : null,
    source: "Price data from CoinGecko, with DexScreener as the fallback.",
  };
}
