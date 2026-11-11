# Vinculum Protocol: public verification

This repository holds the documents and code the team behind Vinculum Protocol
has published so that anyone can check how Vinculum works on Base. Everything
here is open to read and test. Nothing here can change the protocol, and you
are welcome to compare any of it with what is written on chain.

## What is in here

- `price-fetcher/`: the complete price fetcher for Vinculum on Base. It has
  a plain-English guide (`PRICE_FETCHER.md`), the code that runs, the tests,
  and the token list of 2,891 Base assets that it prices.
- `registry/`: the Base asset registry document, Revision E, with all 2,893
  Base rows. The price fetcher's token list is built from it.
- How-to manual: coming soon.

## How to use it

You don't need to take the team's word for anything. Give these documents to
your own AI assistant and ask it to check the team's claims for itself:

- Read the price fetcher code and confirm it only fetches prices and writes
  them, as the guide says.
- Run the tests (instructions are in `price-fetcher/PRICE_FETCHER.md`).
- Rebuild the token list from the registry document and confirm it matches
  the published one.
- Compare the contract addresses and prices with what the Base blockchain
  shows.

If something doesn't match, we want to know.
