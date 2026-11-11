# Vinculum price fetcher

Revision 1, 2026-11-10. Published by the Vinculum Protocol team.

This folder holds the complete price fetcher for Vinculum on Base: the code
that runs, the tests, and the list of assets it prices. Anyone can read it,
run the tests, and compare what it says with what is written on chain.

## What it does

The price fetcher looks up a USD price for every asset in the Base registry
and writes those prices to the Vinculum Verifier contract on Base. The
Verifier uses the price in effect when a lock is created to value that lock.

It does nothing else. It cannot mint, lock or release anything, and it holds
no user funds. The only contract call it makes is

`applyScheduledPriceRun(uint64 runId, ScheduledPriceUpdate[] updates)`

on the Verifier at `0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2` (Base, chain
8453). The Verifier accepts that call from one poster address only, and the
address is readable on the contract as `scheduledPricePoster()`.

The price fetcher applies no tier, ratio or minimum-price rule. It fetches a
price and writes it. Every other rule is in the Verifier.

## Where prices come from

For each asset, in this order:

1. CoinGecko, by the asset's CoinGecko identifier in the registry.
2. If CoinGecko has no price: DexScreener, by the asset's own contract
   address on Base. Of the Base pools that hold the token and give it a USD
   price, the pool with the most liquidity gives the price.
3. One asset, registry row 138, may also be priced from a DexScreener pool
   for its exact contract on another chain.

The first valid price is used. There is no lookup by symbol. There is no
fixed, assumed or substitute price for any asset. A price is valid when it is
above zero at 30 decimal places and fits the Verifier's storage.

Price data is from CoinGecko, with DexScreener as the fallback.

## When it runs

A run prices every asset once. A new run starts at a fixed interval that the
team sets, between 12 hours and 7 days. Run times are counted from
2026-11-10 00:00 UTC. The interval in use is shown by the status call
described below.

A run is done in small pieces. Every five minutes the function is called, and
each call does one piece and saves its place:

- The registry is split into groups of 120 assets.
- One call prices one group and, when posting is on, writes that group's
  prices in one transaction straight away.
- Price lookups are at least four minutes apart.

A run takes between three and five hours.

## What is written

For each asset in a group:

- A valid price: the price is written and the asset is usable for new locks.
- No price, and the asset has a usable price on chain: the asset is marked
  unavailable. New locks of that asset stop until a later run prices it.
  Locks that already exist keep the price they were created with.
- No price, and the asset is already unavailable: nothing is written.

## When a price service does not answer

A service that fails to answer is not the same as a service that answers "no
price".

- If CoinGecko does not answer for a group, the group is tried again on later
  calls. Nothing is written for it in the meantime.
- If a service does not answer for a single asset, nothing is written for that
  asset when its group is written. After all groups are done, those assets
  are tried again slowly, a few per call, up to six more times each. Assets
  that have a usable price on chain are tried first.
- Six hours after a run starts, retries stop. An asset that still has no price
  is then treated as having no price.

## Transactions

- Each transaction carries a run number one higher than the last one the
  Verifier accepted. The Verifier rejects any other number.
- Before a transaction is sent, its exact contents are saved.
- If a transaction does not confirm, the only thing ever sent again is that
  same saved transaction, at the same nonce. A missing confirmation is never
  treated as a reason to sign something new.
- After a transaction confirms, the prices are read back from the Verifier
  and compared with what was sent.
- A transaction is not sent if its estimated cost is above a set limit or the
  poster wallet does not hold enough for gas. Prices already on chain then
  stay as they are.

## Switches

Two settings control it. Both are off unless set.

- `PRICER_ENABLED`: turns the price fetcher on.
- `PRICER_POSTING`: lets it sign and send. With this off, it fetches prices
  and records what it would write, and sends nothing.

The poster's key is held as a secret in the hosting platform. It is not in
this repository and is never logged or stored by the code.

## Status

Calling the function with `{"mode":"status"}` returns a short summary: the
interval, when the next run starts, and the last run's counts. It contains no
keys.

## Files

```
base44/functions/pricerTick/entry.ts       The function. Settings, storage, HTTP, chain.
base44/functions/pricerTick/core.js        The run logic.
base44/functions/pricerTick/prices.js      Price lookup, price maths, the lines to write.
base44/functions/pricerTick/rpc.js         The connection to the Base network.
base44/functions/pricerTick/registry.json  The assets priced: 2,891 Base assets.
base44/entities/                           The saved state: one record of state,
                                           one per run, one per group.
pricer-tests/                              The tests.
pricer-tools/build-registry.mjs            Builds registry.json from the Base registry document.
../registry/assets.full-revE.json          The Base registry document (all 2,893 Base rows).
```

`registry.json` is the Base asset registry, Revision E (2,893 rows, SHA-256
`af8a4fc62af5be7baf50e2fe164e23202de8e03f1f92103d27b490dcfb56e2e6`), without
two excluded contracts, which are listed inside the file.

## Running the tests

With Node.js 20 or newer:

```
cd pricer-tests
npm ci
npm test
```

The tests use stand-ins for the price services, the chain and the clock, so
they need no network and send nothing. They cover a full run over all 2,891
assets, the spacing of lookups, missing prices, services that do not answer,
transactions that fail, revert or never confirm, and two calls at once.
