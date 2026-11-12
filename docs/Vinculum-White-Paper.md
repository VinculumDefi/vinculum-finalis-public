# Vinculum Protocol: A Mechanical Multi-Community Commitment System

**Public Release Candidate (Draft 3 Base-only review) | November 8, 2026**

*Aligned with Vinculum Finalis Master Specification Revision 21 (November 1, 2026), with the Revision 22 VF-TOK-008 text alignment described in Section 4. Companion to the Vinculum Protocol User's Manual. This edition describes the protocol as offered on Base.*

**Author:** Vinculum team

## Abstract

Vinculum Finalis is a time-commitment protocol that lets holders of many different tokens keep their original assets on Base while taking part in a shared mechanical system. A user locks an approved token for a fixed duration, pays a uniform 5% lock fee in that same token to a fixed Dev Fund address, and receives protocol tokens minted up front. When the lock matures, reclaiming the remaining 95% of principal requires nothing but the passage of time on Base. Locked principal is never lent out, and staking carries zero protocol fee, so the 5% lock fee is the single, open place where the protocol collects revenue. This white paper explains the design in plain language for ordinary token holders. Exact tables, rounding rules, contract addresses, and step-by-step instructions live in the companion Vinculum User's Manual.

## 1. Purpose and Core Idea

Across crypto, holders who care about a token, and about the entry price at which they built their position, usually face an unattractive choice if they want to take part in something new. Either they sell or swap their tokens and lose that exposure, or they hand their assets to bridges, wrappers, liquidity pools, or human-administered treasuries.

Vinculum Finalis offers a plain mechanical alternative: a time-commitment protocol that connects many token communities on Base, while letting holders keep ownership of their underlying tokens without selling, wrapping, or bridging them. The protocol does not ask a community to abandon its token. It asks for a fixed-term lock of that token under rules that, once deployed and finalized, no one can rewrite.

Broad community inclusion is intentional and without judgment. The approved registry admits technically compatible tokens through automated lock and release testing rather than market-cap or liquidity gatekeeping. Base launched with 2,893 approved registry entries, plus explicitly disclosed team registry overrides where applicable. Higher issuance multipliers for a small number of designated assets, mainly stablecoins and native gas coins, reflect practical simplicity under fixed rules. They are never a judgment on any community token.

Taken together, these choices form an unusual combination of fixed on-chain rules: no contract owner, upgrade, or rule-change key after finalization, principal that never leaves Base, release that needs nothing but time, and a one-cent trial that anyone can run before committing more. Live verification Handshakes and pre-announcement team locks already on-chain followed those same public rules.

## 2. How a Commitment Vault Lock Works

A Commitment Vault Lock is the core user action. A user selects an approved token on Base and chooses one of 16 fixed lock durations, from the 1-hour Trust-Building Handshake up to 10 years. Longer durations carry higher issuance multipliers. Each lock is a single, fixed-term position. Locks are not renewable, and there is no early exit.

**The 1-Hour Trust-Building Handshake.** Anyone can test the entire lock, mint, and release cycle using a tiny gross value between $0.01 and $0.02 for one hour. The 5% lock fee on a $0.01 Handshake is $0.0005. There is no limit on how many Handshakes a wallet may run, and no identity check. The specification explicitly forbids wallet clustering and person-level identification. The Handshake uses the same uniform 5% lock fee as every other duration.

**Fee and principal isolation.** When a lock is created, a 5% lock fee transfers in the original token to the fixed Dev Fund address on Base, and the remaining 95% of your tokens stay isolated in the vault until maturity. The fee is never swapped or converted. The Dev Fund address on Base was fixed at deployment and cannot be redirected.

**Up-front issuance and unconditional principal release.** Protocol token issuance is calculated on the full Verified Gross USD Value before the 5% lock fee is subtracted, using the posted reference price shown on the offer screen before the user signs. The offer is take-it-or-leave-it: the user sees the exact posted price and when it was posted, then accepts or walks away. Once the lock is verified on-chain, the selected protocol token, VCLM at launch or CHONX after it unlocks, is minted up front to the user's bound recipient address.

When the lock matures, reclaiming the 95% principal requires nothing but time passing on Base. Release never depends on an administrator, a price update, a relayer, or even on protocol token issuance succeeding. If issuance fails for any reason, the locked principal still becomes reclaimable at the unlock time. For ordinary ERC-20 and native locks, maturity sends the recorded 95% principal quantity back to the release wallet. If a rebasing ERC-20's vault balance falls below total owed principal, each open lock of that token receives a pro-rata share (`principal * balance / owedPrincipal`) so no lock is paid from another lock's principal; any positive rebase surplus stays in the vault. Its dollar value at that time depends on the market for that token.

## 3. Where the Protocol Makes Its Money, and Why Locked Tokens Sit Untouched

Every careful holder, and every AI, should ask what the catch is and where the money comes from. Here is the complete answer.

**Why locked tokens are never lent out.** Many DeFi protocols lend deposited tokens to third-party borrowers or place them in outside strategies, then keep a share of what those outside parties pay. Vinculum deliberately does neither, for two reasons.

1. **Broad community inclusion.** Lending markets exist for a small group of large, heavily traded assets. Most community tokens, including most of the 2,893 approved tokens on Base, have no lending market anywhere. A design that depended on lending would shrink eligibility to that small group and shut thousands of communities out completely. Leaving principal untouched lets every technically compatible token take part, which builds a much larger shared network of communities.
2. **No third-party counterparty exposure on the 95% principal.** When tokens are handed to outside borrowers or pools, a failure at that outside party can mean the tokens never come back. In Vinculum, the 95% principal stays inside the immutable vault contract on Base, never leaves it before maturity, and never depends on a third party paying it back. For a holder whose tokens would otherwise sit idle in a wallet, not lending them out takes nothing away and removes outside custody exposure. The exposure that remains is the vault contract code itself, which anyone can read.

Vinculum recognizes time commitment itself, rather than third-party lending exposure.

**Why the 5% lock fee is the single, open revenue point.** Vinculum launched with zero pre-minted tokens, zero team allocation, and zero VC allocation. It never lends or takes any share of the 95% principal. It deliberately charges zero protocol fee on staking, so holders can stake VCLM, CHONX, and SYNTH, queue extensions, claim, withdraw, and stake again over and over for years without paying another protocol fee. Stakes do not keep renewing on their own: a term that ends without a queued extension stops participating until its holder comes back and opens a new stake. With all of that in place, the upfront 5% Commitment Vault Lock fee, sent in the locked token to the fixed Dev Fund on Base, is the single, transparent point where the protocol collects revenue. The 5% lock fee is upfront protocol fee revenue, paid outright to the fixed Dev Fund address on Base with no trust, earmark, reserve, or obligation attached. Separately, as a plain practical fact, the team pays the ongoing price-posting gas and the app and infrastructure hosting costs.

We state the other side plainly as well: the Dev Fund receives the fee when a lock is created, whether or not VCLM ever trades at any price on any market.

## 4. The Three-Token Progression: VCLM, CHONX, and SYNTH

**Zero pre-mine.** The Base protocol tokens started at a total supply of zero, with no pre-minted tokens and no pre-existing supply. There is no team allocation, no venture allocation, and no team mint function. Solely two immutable smart contracts on Base can ever mint VCLM: the Commitment Vault Verifier, for verified locks, and the Treasury Reward Stake contract, for completed reward epochs. Protocol tokens carry no transfer tax, freeze list, or protocol trading restriction.

**Counted milestones, not dates or votes.**

- **VCLM** is available from launch on Base, with a hard cap of 10 billion. Its issuance rate steps down in fixed 30-day periods to a permanent floor.
- **CHONX**, with a hard cap of 100 billion on Base, unlocks permanently once cumulative lifetime VCLM minted on Base reaches 10,000,000. After that, a user creating a new lock chooses VCLM or CHONX. One lock never issues both.
- **SYNTH**, with a hard cap of 10 million on Base, becomes available through the SYNTH Forge once cumulative lifetime CHONX minted on Base reaches 100,000,000. SYNTH is never issued from a lock.

**Voluntary SYNTH forging.** Forging SYNTH is 100% voluntary. A holder who chooses to forge permanently burns 1,000 VCLM and 10,000 CHONX for each SYNTH. Burns cannot be reversed and never restore lifetime issuance caps. The Forge function `forge(uint256 count)` accepts whole numbers of SYNTH (1, 2, 3, and so on; no fractional SYNTH forging). Keeping VCLM and CHONX forever, and never forging at all, is fully supported.

**The CHONX rate clock on the live contracts.** On Base, the deployed Verifier measures the 30-day step-down schedule for both VCLM and CHONX from the Base protocol launch, while CHONX itself stays locked until 10,000,000 lifetime VCLM have been minted on Base. The written text of VF-TOK-008 is updated in Master Specification Revision 22 to match this live behavior. Two things follow. If several 30-day periods pass before 10,000,000 VCLM are minted, CHONX opens at that period's stepped-down rate rather than 100 CHONX per $1.00, so each dollar mints fewer than 100 CHONX. If the community reaches 10,000,000 VCLM sooner, CHONX opens at a starting rate closer to 100 per $1.00. In plain math, if CHONX unlocks in a later 30-day period at a stepped-down per-dollar rate, reaching 100,000,000 lifetime CHONX to open the SYNTH Forge requires proportionally more cumulative USD lock volume.

Protocol tokens can never be locked in a Commitment Vault Lock. Caps, supplies, and unlock counters are counted on Base.

## 5. Treasury Reward Stake

Treasury Reward Stake is separate from Commitment Vault Locks. It is active from launch and charges zero protocol fee. Opening a stake, queuing a future extension, claiming VCLM, and withdrawing all carry zero protocol fee. Users pay network gas and nothing else.

**About the name.** In the Solidity code, the staking contract is named `VinculumFinalisStake`, and its code comments and the specification call the mechanism the Treasury Reward Stake. The word Treasury refers to the protocol's unminted token issuance reserve under the fixed VCLM cap on Base, not a pool of outside assets backing the token.

Holders commit VCLM, and CHONX or SYNTH once they exist on Base, for fixed terms of 30, 60, 90, or 120 days. Longer terms and higher-tier protocol tokens carry higher stake weight. The contract lets a holder queue one future term at a time while a stake is active. The web interface surfaces the extension controls during the final 30 days of an active term, so that staking stays a deliberate choice rather than something left running unattended.

Rewards work without touching the Dev Fund. Every verified lock fee records a one-time Reward-Accounting Credit equal to 60% of the verified USD fee value. Those credits are grouped into fixed 10-day epochs and converted at a permanent internal constant of $0.10 into newly minted VCLM, subject to the remaining VCLM lifetime cap on Base. In plain terms, every $1.00 of verified lock fee adds 6 VCLM to that epoch's reward pool. Newly minted VCLM is allocated in proportion to stake weight to eligible stakes that remain active across the reward epoch and the following 10-day epoch.

Reward-Accounting Credits are pure on-chain accounting numbers. They are never a deposit, a pool, or a claim on Dev Fund assets, and no outside assets back stake rewards. When remaining VCLM capacity on Base reaches zero, new stakes and extensions permanently close, existing staked tokens become withdrawable, and any already-recorded claimable VCLM stays available.

## 6. Fixed Internal Accounting Numbers and Two-Way Market Dynamics

The $0.10 reward constant and the starting lock schedules of 10 VCLM and 100 CHONX per $1.00 are never claims about, or anchors for, what VCLM or CHONX should trade for on any outside market. The protocol was permanently bound to fixed internal accounting numbers on purpose, so the rules treat every participant identically and nobody, including the team, can ever change them later.

Because the constants are fixed while outcomes vary, the upfront lock fee per minted VCLM varies widely by asset class, duration, and 30-day period. At the starting rate, a $100 lock of an S3 token pays a $5 lock fee and mints 1,000 VCLM for 7 days, up to 8,000 VCLM for 10 years, or 12,000 VCLM for a 10-year lock of USDC on Base. In every case the user also time-locks the 95% principal for the chosen term.

If external liquidity pools or markets ever form, that creates genuinely interesting two-way dynamics:

- **If an outside market price ever sits above the upfront lock fee per minted VCLM, even after weighing the chosen time-lock commitment of the 95% principal,** participants may prefer locking approved tokens through the protocol over buying VCLM on the open market, which would encourage new locks and expand supply.
- **If an outside market price ever sits below the upfront lock fee per minted VCLM, once the time-lock commitment is weighed in as well,** participants may prefer acquiring VCLM on the open market rather than paying a 5% lock fee, which would slow new lock issuance while people stake those tokens with zero staking fee or burn them in the voluntary SYNTH Forge.

We make zero promises about market price or liquidity, and nobody knows in advance how participants will react as these moving parts interact in both directions. Watching how communities work through that interplay is part of what makes the design genuinely dynamic and fun to observe.

## 7. A Standalone Deployment on Base

As of November 2026, Vinculum Finalis is deployed, finalized, and live on Base (VCLM).

The Base deployment is standalone, with its own contracts, its own Approved Asset Registry, its own scheduled price poster, its own Dev Fund destination, and its own scorecard. Nothing is bridged or wrapped. Locked tokens stay on Base.

## 8. Immutability, Price Posting, and Honest Limits

**Post-finalization immutability.** At the end of the Base deployment ceremony, configuration was finalized and `deployer()` was irreversibly cleared to the zero address. There is no governance vote, council, multisig owner, proxy upgrade path, pause switch, emergency withdrawal, or rescue key. An accepted consequence of removing every contract owner, upgrade, and rule-change key is that deployed contract logic cannot be patched in place. No one, including the team, can change deployed contract rules, move locked principal, pause withdrawals, upgrade contracts, or alter token caps. Live verification Handshakes and pre-announcement team Commitment Vault Locks are already on-chain. They paid the same 5% Dev Fund fee and minted VCLM under the exact same public rules, so VCLM `totalSupply()` is already above zero.

**What the price poster can and cannot do.** Blockchains cannot fetch CoinGecko or DexScreener on their own, so the Base Verifier accepts scheduled price runs from one fixed `scheduledPricePoster` address. That address was locked permanently at `finalize()`, so nobody can swap in a different poster. The team runs the price job on a team-set schedule, once every 4 days at launch, using an ordered lookup cascade: CoinGecko by configured ID, then DexScreener by exact contract. A posted price stays in effect until the next run, and the official app shows the exact posted price and its posting time before a user signs. The poster can post USD values for valuing new locks, and it can mark an individual asset `usable = false`, which marks that asset unusable for new lock valuation and VCLM or CHONX minting until a later successful run. The official app does not offer a new lock on that token, while a hand-built lock transaction still routes the 5% fee and holds 95% principal and then cannot verify or mint until a usable price exists. Existing locks are never affected. It cannot move or release principal, mint tokens, reprice existing locks, or change any rule. Releasing matured principal never reads a price and never touches the Verifier, so it works even if the poster stopped forever.

**Thin tokens and glass-box price rules.** Even if a thinly traded token briefly spikes, anyone trying to use that price still has to send 5% of a real token stack permanently to the Dev Fund and time-lock the other 95%, and cannot touch anyone else's principal. A briefly high posted price could still let a lock mint more VCLM than usual, which adds to supply. For that reason, the team publishes the price-fetching rules alongside the contract files in the Vinculum public verification repository, so that anyone, or their AI, can compare live API quotes against the `scheduledPrices` values on-chain.

**Plain user trade-offs.** Users must accept the following:

- Locked principal cannot be withdrawn early under any circumstance.
- The 5% lock fee transferred to the Dev Fund is permanently non-refundable, including for a transaction built by hand outside the official app's checks.
- The contracts went through extensive testing by the team, including automated test suites, test network runs, live small-value Handshakes on Base, and AI red teaming. They have not undergone a third-party external security review by an outside firm.
- VCLM, CHONX, and SYNTH are mechanical protocol tokens with no promise of any market price, liquidity, exchange listing, redemption right, or financial outcome.

## 9. Don't Trust Us: Check Everything With Our Docs and Your AI

Nobody needs to take a summary on faith, and nobody should lock meaningful value before checking how the system behaves. The Vinculum team invites every reader to verify the claims in this paper directly.

1. **Read the User's Manual with your own AI.** The User's Manual carries every table, formula, worked example, and contract address, plus two ready-to-paste prompts: one that asks your AI to examine the protocol skeptically, and one that sets your AI up as a personal helper for checking addresses and computing issuance.
2. **Verify immutability on-chain.** Ask your AI, or check directly with a block explorer or RPC, to read `deployer()` and `configurationFinalized()` on the Base Verifier. On the finalized Base deployment, `deployer()` reads as the zero address and `configurationFinalized()` reads as `true`.
3. **Run a $0.01 One-Hour Handshake.** Test the live contracts for a penny. Watch the 5% lock fee route to the fixed Dev Fund address, receive VCLM up front, and reclaim 95% of your test token after 60 minutes before deciding whether to commit more.

Vinculum Finalis is a set of fixed mechanical contracts and counted milestones. Read the Manual, check the chain, and try the Handshake. Then decide for yourself.
