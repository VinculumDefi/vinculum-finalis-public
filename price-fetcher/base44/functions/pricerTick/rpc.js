// Vinculum price fetcher: the connection to the Base network.
//
// Public Base endpoints are shared and often refuse a caller for a while.
// This provider keeps a list of endpoints. Each request goes to the endpoint
// that last answered. If it refuses, times out or is unreachable, the request
// moves straight on to the next endpoint. It never waits a long time on one
// endpoint.
//
// An answer that is a real result from the chain, including "this call would
// revert", is returned as it is and is not sent anywhere else.

const BUSY = /rate|limit|too many|capacity|exceeded|overload|timeout|temporar|unavailable|try again/i;

export function makeBaseProvider(ethers, urls, chainId, { fetchImpl = fetch, timeoutMs = 10000, rounds = 2, pauseMs = 2000, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  if (!urls.length) throw new Error("no Base endpoint is configured");
  let current = 0;
  const failures = [];

  async function ask(url, payload) {
    const res = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (res.status !== 200) throw new Error("HTTP " + res.status);
    const json = JSON.parse(await res.text());
    const list = Array.isArray(json) ? json : [json];
    for (const item of list) {
      if (!item || typeof item !== "object" || !("id" in item)) throw new Error("not a JSON-RPC answer");
      const e = item.error;
      // -32000 with revert data is a real chain answer. Refusals for being
      // busy are not, so they move the request to the next endpoint.
      if (e && !e.data && (e.code === 429 || e.code === -32005 || e.code === -32016 || e.code === -32603 || BUSY.test(String(e.message || "")))) throw new Error("endpoint busy: " + String(e.message || e.code).slice(0, 80));
    }
    return list;
  }

  class BaseProvider extends ethers.JsonRpcApiProvider {
    constructor() {
      const network = ethers.Network.from(chainId);
      super(network, { staticNetwork: network, batchMaxCount: 1 });
    }
    async _send(payload) {
      let last = "no attempt";
      for (let round = 0; round < rounds; round++) {
        if (round > 0) await sleep(pauseMs);
        for (let i = 0; i < urls.length; i++) {
          const index = (current + i) % urls.length;
          try {
            const out = await ask(urls[index], payload);
            current = index;
            return out;
          } catch (e) {
            last = String((e && e.message) || e).slice(0, 120);
            failures.push({ endpoint: index, why: last });
          }
        }
      }
      throw new Error("no Base endpoint answered (" + last + ")");
    }
  }
  const provider = new BaseProvider();
  provider.endpointFailures = failures;
  return provider;
}
