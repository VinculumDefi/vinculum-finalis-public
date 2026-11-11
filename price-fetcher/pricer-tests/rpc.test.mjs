import test from "node:test";
import assert from "node:assert/strict";
import { ethers } from "ethers";
import { makeBaseProvider } from "../base44/functions/pricerTick/rpc.js";

const ok = (body) => ({ status: 200, text: async () => JSON.stringify(body) });
const result = (payload, value) => ok({ jsonrpc: "2.0", id: payload.id, result: value });
function net(handlers) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const payload = JSON.parse(init.body);
    calls.push({ url, method: payload.method });
    return handlers[url](payload);
  };
  return { calls, fetchImpl };
}
const opts = (n) => ({ fetchImpl: n.fetchImpl, sleep: async () => {}, pauseMs: 0 });

test("a refused endpoint is skipped at once and the next one answers", async () => {
  const n = net({
    a: async () => ({ status: 429, text: async () => "slow down" }),
    b: async (p) => result(p, "0x10"),
  });
  const provider = makeBaseProvider(ethers, ["a", "b"], 8453, opts(n));
  assert.equal(await provider.send("eth_blockNumber", []), "0x10");
  assert.deepEqual(n.calls.map((c) => c.url), ["a", "b"]);
  assert.equal(await provider.send("eth_blockNumber", []), "0x10");
  assert.equal(n.calls.at(-1).url, "b", "it stays with the endpoint that answered");
  assert.equal(n.calls.length, 3);
});

test("busy answers, unreachable endpoints and bad answers all move on", async () => {
  const n = net({
    a: async (p) => ok({ jsonrpc: "2.0", id: p.id, error: { code: -32005, message: "rate limit exceeded" } }),
    b: async () => { throw new Error("connection reset"); },
    c: async () => ({ status: 200, text: async () => "<html>" }),
    d: async (p) => result(p, "0x2a"),
  });
  const provider = makeBaseProvider(ethers, ["a", "b", "c", "d"], 8453, opts(n));
  assert.equal(await provider.getBlockNumber(), 42);
  assert.deepEqual(n.calls.map((c) => c.url), ["a", "b", "c", "d"]);
  assert.equal(provider.endpointFailures.length, 3);
});

test("a real revert from the chain is returned, not retried elsewhere", async () => {
  const n = net({
    a: async (p) => ok({ jsonrpc: "2.0", id: p.id, error: { code: 3, message: "execution reverted", data: "0x08c379a0" + "00".repeat(32) } }),
    b: async (p) => result(p, "0x"),
  });
  const provider = makeBaseProvider(ethers, ["a", "b"], 8453, opts(n));
  await assert.rejects(provider.call({ to: "0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2", data: "0x00" }), (e) => e.code === "CALL_EXCEPTION");
  assert.ok(n.calls.every((c) => c.url === "a"));
});

test("when no endpoint answers, it gives up quickly with a clear error", async () => {
  const n = net({ a: async () => ({ status: 503, text: async () => "" }), b: async () => ({ status: 429, text: async () => "" }) });
  const provider = makeBaseProvider(ethers, ["a", "b"], 8453, opts(n));
  await assert.rejects(provider.getBlockNumber(), /no Base endpoint answered/);
  assert.equal(n.calls.length, 4, "two rounds, then stop");
});
