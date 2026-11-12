# Vinculum Protocol User's Manual

## AI-Ready Companion Edition

**Public Release Candidate (Draft 3 Base-only review) | November 8, 2026**

*Aligned with Vinculum Finalis Master Specification Revision 21 (November 1, 2026). Companion to the Vinculum Protocol White Paper. This edition describes the protocol as offered on Base.*

**Author:** Vinculum team

**Website:** https://vinculumprotocol.com

## About This Manual

The Vinculum Protocol White Paper explains the design in plain language and leaves the exact numbers, tables, rounding rules, contract addresses, and step-by-step instructions to this manual. Everything the White Paper said would live in a companion document is here.

This manual is written for two readers at once:

1. **You**, a token holder who wants to understand exactly what happens to your tokens before you sign anything.
2. **Your own AI assistant**, such as ChatGPT, Grok, Claude, or Cursor, which you can hand this file to so it can check our claims, recompute any transaction, and walk you through each step.

Every number in this manual comes from the governing Master Specification (Revision 21) or from the deployed, verified contracts on Base. Wherever this manual describes how something works, it describes what the deployed contracts actually do, because the live contracts are what your tokens interact with.

The deployed contracts cannot be changed. If a later version of this manual corrects a description, the contracts themselves will still behave exactly as deployed.

## 1. How to Use This Manual with Your Own AI

You do not have to take any summary on faith, including this one. The protocol was built so that an ordinary holder, with the help of an AI assistant, can check how it works before committing anything meaningful.

**What to give your AI:**

- This manual (the Markdown or PDF file).
- The verified Solidity source. You can point your AI at the verified code on BaseScan or Sourcify using the addresses in Section 10, or at the Vinculum public verification repository, which holds the contract files and the price-fetching rules.
- Optionally, the White Paper, for the plain-language overview.

### Prompt A: The "Is This Legit, and How Do They Make Money?" Skeptic Review Prompt

Copy and paste this into your AI along with this manual and the verified contract source:

> I am considering using Vinculum Protocol. I want you to act as a skeptical reviewer, not a promoter. Using the attached User's Manual and the verified Solidity contracts, explain in plain English what Vinculum Protocol does, where my locked tokens sit, whether there is any admin key, pause switch, proxy upgrade, lending or rehypothecation of my tokens, or team pre-mine, and exactly how the protocol collects fees and where those fees go.
>
> Then check each of these against the code itself, quoting the function names you rely on:
>
> 1. When I create a lock, where does each part of my tokens go, and in what amounts?
> 2. Can anyone, including the team, move my locked tokens, release them early, or redirect them?
> 3. Which addresses can mint VCLM, CHONX, and SYNTH, and can that list ever change?
> 4. Is there any owner, deployer, governance, pause, upgrade, or rescue function still active after finalization?
> 5. What exactly can the scheduled price poster address do, and what can it not do?
> 6. Does staking charge any protocol fee?
> 7. What happens to my lock if no usable price is posted?
> 8. Is there anything in the code that contradicts the manual?
>
> Tell me plainly anything you could not confirm, and anything that concerns you.

**The transparent answer your AI should find.** We state it here so you can compare it with what your AI reports:

- **No pre-mine, no insider allocation.** On Base, VCLM, CHONX, and SYNTH started at a total supply of zero. There were no pre-minted tokens, no pre-sale, no team allocation, and no venture or VC allocation. The Vinculum team started at zero alongside every other user and acquires protocol tokens by the same rules as everyone else. Live verification Handshakes and pre-announcement team Commitment Vault Locks are already on-chain. They paid the same 5% Dev Fund fee and minted VCLM under the exact same public rules, so VCLM `totalSupply()` is already above zero.
- **Two minting contracts for VCLM, one for CHONX, one for SYNTH.** Solely two immutable contracts on Base can mint VCLM: the Commitment Vault Verifier, for verified locks, and the Treasury Reward Stake contract, for completed reward epochs. CHONX can be minted solely by the Verifier. SYNTH is created solely by the SYNTH Forge, and solely by burning VCLM and CHONX. These minter addresses were set once at deployment and cannot be changed.
- **How the protocol collects fees.** Every Commitment Vault Lock pays a uniform 5% lock fee. That fee is paid in the same token you lock, and it is sent directly, in the same transaction, to the fixed Dev Fund address on Base. The fee is never swapped, converted, bridged, or split. The other 95% of your tokens stays isolated in the immutable lock contract on Base until your maturity time. Nobody can move it in the meantime, and at maturity it can be released solely to the release wallet you set when you created the lock.
- **Staking has no protocol fee.** Opening a stake, queuing an extension, claiming VCLM, and withdrawing all carry zero protocol fee, forever. You pay normal network gas and nothing else.
- **No Contract Owner, Upgrade, or Rule-Change Key.** After the Base deployment ceremony, configuration was finalized and the deployer role was cleared to the zero address. There is no owner, no governance, no pause, no upgrade, no proxy, and no rescue function. Locked tokens are never lent out, pooled for lending, or rehypothecated.
- **What the 5% lock fee is.** The 5% lock fee is upfront protocol fee revenue, paid outright to the fixed Dev Fund address on Base with no trust, earmark, reserve, or obligation attached. Users hold no claim on Dev Fund assets (Section 9.7).
- **What the team pays for.** As a plain practical fact, the team pays the ongoing network gas for posting prices on Base and the app and infrastructure hosting costs.
- **The whole picture in one place.** Section 2 explains, in full, where the protocol's money comes from, why locked tokens sit untouched instead of being lent out, and why the internal accounting numbers are fixed forever.

### Prompt B: "Turn Your AI Into a Vinculum Helper" Prompt

Paste this to set your AI up as a personal Vinculum helper. Many AI tools let you save it as a custom instruction, project, or skill.

> You are my Vinculum Protocol helper. Use the attached Vinculum Protocol User's Manual, Public Release Candidate (Draft 3 Base-only review), aligned with Master Specification Revision 21, as your reference. Follow these rules:
>
> 1. **Check addresses before I sign.** Whenever I paste a wallet confirmation screen or a contract address, compare it character by character with the Verified Live Contract Directory in Section 10 of the manual. Also confirm the chain ID is Base 8453. If anything does not match, tell me to reject the transaction.
> 2. **Compute issuance exactly.** For a lock, use: Output = Verified Gross USD Value x current emission rate x asset multiplier x duration multiplier. Use the full gross USD value before the 5% lock fee. Apply the factors in that order and round down. Get the emission rate from the decay table in Section 9.2 using the number of complete 30-day periods since the Base launch time in Section 9.12. Get the asset class from Section 9.4 and the duration multiplier from Section 9.3.
> 3. **Compute the fee and principal exactly.** Fee units = floor(gross units x 500 / 10,000). Principal units = gross units minus fee units.
> 4. **Explain stake weight and epochs.** Weight = staked amount x token multiplier x staking duration multiplier (Section 9.8). Tell me which 10-day epochs my stake qualifies for using the N and N+1 rule in Section 9.9, and when each one becomes claimable.
> 5. **Walk me through steps one at a time.** For a Handshake, lock, release, stake, extension, claim, or forge, use the step lists in Sections 5 to 8. Wait for me to confirm each step before giving the next one.
> 6. **Be honest about limits.** Remind me that there is no early unlock, the 5% lock fee is non-refundable, protocol tokens carry no promise of any market price, and prices are posted on a schedule rather than live.
> 7. **Never ask for my seed phrase or private key**, and warn me if anyone else does.

## 2. Where Does the Protocol Make Its Money, and Why Do Locked Tokens Sit Untouched?

This is the most important question any careful holder, or any AI, can ask: what is the catch, and where does the money come from? Here is the complete answer. Every part of it matches the contract code and can be checked with the steps in Section 10.

### 2.1 Why Locked Tokens Sit Untouched Instead of Being Lent Out

Many DeFi protocols take deposited tokens and lend them to third-party borrowers, or place them in outside strategies, and then keep a share of what those outside parties pay. Vinculum deliberately does neither. The Lock contract has no function that sends principal anywhere except to your release wallet at maturity. There are two reasons for this choice.

1. **Broad community inclusion.** Lending markets exist for a small group of large, heavily traded assets. Most community tokens, including most of the 2,893 approved tokens on Base, have no lending market anywhere. If Vinculum depended on lending locked tokens to outside borrowers, eligibility would shrink to that small group, and thousands of communities would be shut out completely. Leaving principal untouched lets any technically compatible token take part, which builds a much larger shared network of communities for everyone.
2. **No third-party counterparty exposure on your 95% principal.** When tokens are handed to outside borrowers or pools, a failure at that outside party can mean the tokens never come back. Your 95% principal stays inside the immutable vault contract on Base, never leaves it before maturity, and never depends on a third party paying it back. For a holder whose tokens would otherwise sit idle in a wallet, or locked somewhere else, not lending them out takes nothing away and removes outside custody exposure. The exposure that remains is the vault contract code itself, which is exactly why Section 10 shows you how to inspect it.

Vinculum recognizes **time commitment itself**, rather than third-party lending exposure.

### 2.2 Why the 5% Lock Fee Is the Single, Open Revenue Point

Consider everything the protocol does not do:

- It launched with zero pre-minted tokens, zero team allocation, and zero VC allocation.
- It never lends, borrows against, or takes any share of your 95% principal.
- It deliberately charges zero protocol fee on staking. You can stake VCLM, CHONX, and SYNTH, queue extensions, claim, withdraw, and stake again over and over for years without paying another protocol fee.

Stakes do not keep renewing on their own. If you let a term end without queuing your next extension, that stake stops participating at the end of its term until you come back and open a new stake.

With all of that in place, the upfront 5% Commitment Vault Lock fee, sent in the locked token to the fixed Dev Fund on Base, is the single, transparent point where the protocol collects revenue. The 5% lock fee is upfront protocol fee revenue, paid outright to the fixed Dev Fund address on Base with no trust, earmark, reserve, or obligation attached. You can see it in every lock transaction: the Lock contract emits a `FeeRouted` event naming the Dev Fund and the exact fee amount, and the Dev Fund address can be read from the Lock contract's `devFund()` at any time. Separately, as a plain practical fact, the team pays the ongoing price-posting gas and the app and infrastructure hosting costs.

We also state the other side plainly so you can weigh it: the Dev Fund receives the fee when a lock is created, whether or not VCLM ever trades at any price on any market.

### 2.3 Fixed Internal Accounting Numbers and Two-Way Market Dynamics

The protocol uses a few internal accounting constants:

- **The $0.10 Reward Reference Value**, written in the code as `REWARD_REFERENCE_CENTS = 10`. Its sole job is to convert fee credits into stake reward issuance. A $1.00 verified lock fee creates a $0.60 Reward-Accounting Credit, and $0.60 divided by $0.10 adds 6 VCLM to that epoch's stake reward pool.
- **The starting lock schedules** of 10 VCLM per $1.00 and 100 CHONX per $1.00 of Verified Gross USD Value, which step down over time as shown in Section 9.2.

These numbers are never claims about, or anchors for, what VCLM or CHONX should trade for on any outside market. The protocol was permanently bound to fixed internal accounting numbers on purpose, so that the rules treat every participant identically and nobody, including the team, can ever change them later.

Because the constants are fixed while outcomes vary by asset class, duration, and 30-day period, the lock fee paid per minted VCLM varies widely. At the starting rate, a $100 lock pays a $5 lock fee in every case below:

| $100 lock at the starting rate | VCLM minted | Upfront lock fee per minted VCLM |
|---|---|---|
| S3 token, 7 days | 1,000 | $0.005 |
| S3 token, 1 year | 2,500 | $0.002 |
| S3 token, 10 years | 8,000 | $0.000625 |
| S1 USDC on Base, 10 years | 12,000 | about $0.000417 |

In every row, the user also time-locks the 95% principal for the chosen term, so the upfront lock fee per minted VCLM is never the whole commitment.

If external liquidity pools or markets ever form for VCLM, these fixed numbers create genuinely interesting two-way dynamics:

- **If an outside market price ever sits above the upfront lock fee per minted VCLM, even after weighing the chosen time-lock commitment of the 95% principal,** participants may prefer locking approved tokens through the protocol over buying VCLM on the open market. That would encourage new locks and expand supply.
- **If an outside market price ever sits below the upfront lock fee per minted VCLM, once the time-lock commitment is weighed in as well,** participants may prefer acquiring VCLM directly on the open market rather than paying a 5% lock fee. That would slow new lock issuance, while people stake those tokens with zero staking fee or burn them in the voluntary SYNTH Forge at 1,000 VCLM plus 10,000 CHONX for 1 SYNTH.

We make zero promises about market price or liquidity, and nobody knows in advance how participants will react as these moving parts interact in both directions. Watching how communities work through that interplay is part of what makes the design genuinely dynamic and fun to observe.

## 3. Quick Facts at a Glance

| Item | Value |
|---|---|
| Live chain | Base (chain ID 8453) |
| Lock fee | 5% on every duration, paid in the locked token to the Base Dev Fund |
| Principal kept for you | 95% of your locked tokens, released at maturity (rebasing token detail in Section 12) |
| Issuance basis | 100% of Verified Gross USD Value, before the 5% lock fee |
| Lock durations | 16 fixed durations, from the 1-hour Handshake to 10 years |
| Handshake value band | $0.01 to $0.02 inclusive, 1 hour, no limit on how many |
| Minimum for other durations | $0.01 Verified Gross USD Value |
| Early unlock | None |
| Protocol tokens | VCLM, CHONX, SYNTH, each with 18 decimals |
| Starting supply | Zero on Base, with no pre-minted tokens |
| CHONX unlock | 10,000,000 lifetime VCLM minted on Base |
| SYNTH Forge unlock | 100,000,000 lifetime CHONX minted on Base |
| Forge recipe | Burn 1,000 VCLM + 10,000 CHONX for 1 SYNTH, voluntary |
| Staking terms | 30, 60, 90, or 120 days |
| Staking protocol fee | Zero, on every action |
| Reward epochs | Fixed 10-day epochs from the Base launch |
| Price schedule | Team-run price job, once every 4 days at launch |
| Owner or rule-change control after finalization | None; narrow price-poster role in Section 11 |

## 4. Before You Sign Anything: Wallet Checking Habits

These habits apply to every action in this manual.

1. **Use the official site.** Go to https://vinculumprotocol.com by typing it yourself. Vinculum never asks for your seed phrase or private key. Treat any message, site, or person who asks for one as fraud.
2. **Confirm you are on Base.** Your wallet must be connected to Base, chain ID 8453. If your wallet window shows a different chain, reject the transaction.
3. **Do not bridge protocol tokens.** The protocol tokens described in this manual are the Base tokens: VCLM, CHONX, and SYNTH. Use them on Base.
4. **Check the exact contract address.** Before you approve, compare the destination address in your wallet window with the Verified Live Contract Directory in Section 10. A lock or release goes to the Commitment Vault Lock contract. A stake, extension, claim, or withdrawal goes to the Stake contract. A forge goes to the Forge contract. An approval names the token contract and gives permission to the Lock, Stake, or Forge contract.
5. **Check the amounts.** An approval should cover the amount you are about to lock, stake, or forge. The posted price, its posting time, the fee, and the expected output are shown in the app before your wallet opens.
6. **Expect a new-contract warning.** Browser wallets often warn about recently deployed contracts. That warning is not a verdict on the contract. Your own address and amount checks are what matter.
7. **Keep a little native coin for gas.** Every transaction needs a small amount of ETH on Base for gas.

## 5. Step-by-Step: The 1-Hour Handshake

The Trust-Building Handshake is the smallest real lock. It lets you see the complete cycle with a tiny amount: lock, receive VCLM, wait one hour, and release your principal.

**What it costs.** A full Handshake uses 3 wallet confirmations at lock time (4 if an ERC-20 token needs an approval beforehand) plus 1 confirmation to release after an hour, each costing normal network gas. A Handshake has a Verified Gross USD Value of $0.01 to $0.02. The 5% lock fee on a $0.01 Handshake is $0.0005, which is five hundredths of a penny. On a $0.02 Handshake it is $0.001. You also pay normal network gas, which on Base is usually a fraction of a cent per transaction.

**There is no limit.** A wallet may run any number of Handshakes. There is no identity check and no wallet tracking.

**Steps:**

1. **Open the site and connect your wallet.** Go to https://vinculumprotocol.com, open the Lock page, and connect a browser wallet such as MetaMask, Coinbase Wallet, or Rabby.
2. **Confirm you are on Base.** Your wallet should show chain ID 8453.
3. **Check the lock contract address.** Compare the Commitment Vault Lock address shown in the app and in your wallet with Section 10 of this manual.
4. **Choose an approved token and the 1-hour duration.** Enter an amount worth $0.01 to $0.02. The app shows the posted reference price for that token and the date and time it was posted. If you do not accept that price, stop here and nothing moves.
5. **Approve, if needed.** For an ERC-20 token, your wallet asks you to approve the lock contract for the amount you entered. For ETH, the native coin on Base, no approval is needed because the coin is sent with the lock itself.
6. **Create the lock.** Confirm the lock in your wallet. In that same transaction, 5% of your tokens goes to the Base Dev Fund and the other 95% is held in the lock contract with a maturity time exactly 1 hour later.
7. **Record the fee credit and mint.** The lock transaction itself moves the fee and the principal together in one step. Issuance is a separate step: the app then asks for one or two more confirmations to record the lock's fee credit with the Verifier and to verify the lock and mint your VCLM. VCLM arrives in your recipient wallet right after verification. It does not wait for the hour to pass.
8. **Wait 1 hour.** The release button stays unavailable until the maturity time.
9. **Release.** After the hour, sign the release from the release wallet you set when you created the lock. The 95% principal comes back to that wallet. Release does not depend on prices, on the Verifier, or on any person.

**A worked example on Base:** a Handshake of 0.015 USDC, which is 15,000 units at 6 decimals, posted at $1.00, has a Verified Gross USD Value of $0.015. Base USDC is class S1, so the output is $0.015 x 10 x 1.5 x 1.0 = 0.225 VCLM. The fee is 0.00075 USDC and the principal released after the hour is 0.01425 USDC.

## 6. Step-by-Step: Standard Lock and Release

A standard lock follows the same steps as the Handshake, with any of the 15 longer durations from 7 days to 10 years and a minimum of $0.01 Verified Gross USD Value.

**Before you lock, know these rules:**

- Each lock is a single, fixed-term position. Locks are not renewable. After maturity you release your principal, and you may create a separate new lock if you wish.
- There is no early unlock, cancellation, or penalty exit for any reason.
- One lock issues exactly one output token. VCLM is available from launch. After CHONX unlocks on Base, you may choose VCLM or CHONX for a new lock, never both.
- The price shown on the offer screen is the price used for your lock, and it stays with that lock.

**Lock steps:**

1. Connect your wallet on https://vinculumprotocol.com and confirm your wallet is on Base (chain ID 8453).
2. Choose an approved token, the amount, the duration, and the output token. Review the posted price and its posting time, the 5% lock fee, the principal, the maturity date, and the expected output.
3. Approve the token for the lock contract if it is an ERC-20, checking the address against Section 10.
4. Create the lock. The 5% lock fee goes to the Dev Fund and the 95% principal is held in the lock contract.
5. Confirm the fee credit and verification steps. Your VCLM or CHONX arrives in your recipient wallet up front.

**Release steps:**

1. At or after the maturity time, open the lock in the app from the release wallet you set at lock time.
2. Sign the release transaction to the Commitment Vault Lock contract.
3. The 95% principal comes back to the release wallet. Each lock can be released one time.

## 7. Step-by-Step: Treasury Reward Stake

Treasury Reward Stake is separate from locks. It is active from launch on Base.

**About the name.** In the Solidity code, the staking contract is named `VinculumFinalisStake`, and its code comments and the specification call the mechanism the Treasury Reward Stake. The word Treasury refers to the protocol's unminted token issuance reserve under the fixed VCLM cap on Base, not a pool of outside assets backing the token. Stake rewards are newly minted VCLM, and no outside assets back them.

VCLM, CHONX, and SYNTH are the three stakeable tokens, and CHONX and SYNTH become stakeable once they exist on Base. Staking carries zero protocol fee on every action. You pay normal network gas and nothing else.

**Open a stake:**

1. Connect your wallet and confirm your wallet is on Base.
2. Open the Stake page and choose the token (VCLM, CHONX, or SYNTH), the amount, and the term: 30, 60, 90, or 120 days.
3. Approve the Stake contract for that amount, checking the address against Section 10.
4. Confirm the stake. Any positive amount is accepted.

**Queue an extension:**

1. While your stake is still active, you may queue one future term of 30, 60, 90, or 120 days.
2. The queued term begins exactly at the scheduled end of your current term. Your current multiplier stays the same until then.
3. One future term may be queued at a time. After it begins, you may queue another.
4. Queuing adds or removes no tokens and carries zero protocol fee.
5. The contract allows queuing one future term at any time while the stake is active (VF-STK-021). The web interface surfaces the extension controls during the final 30 days of an active term, so that staking stays a deliberate choice rather than something left running unattended.
6. Once a queued term has begun, you can send a short transaction to record it (`applyExtensionIfMatured`), which then lets you queue another term. The queued term counts toward epoch eligibility whether or not you send that transaction.
7. If you do not queue an extension, your stake becomes inactive at maturity, and an expired stake cannot be extended to cover a gap afterward.

**Claim VCLM:**

1. Reward VCLM for an epoch becomes claimable after that epoch and the following epoch have both ended and the epoch has been closed and allocated on-chain. Anyone may submit the close and allocate transactions, and the team submits them on schedule.
2. Open the Stake page and claim. Your accumulated VCLM is sent to your wallet in one transaction.
3. Claimable VCLM never expires. Withdrawing your stake does not erase it.

**Withdraw:**

1. At or after the scheduled end of your stake, including any queued term that has begun, withdraw from the Stake page.
2. Your full staked amount comes back to your wallet.

## 8. Step-by-Step: Voluntary SYNTH Forge

SYNTH is never issued from a lock. It is created solely through the one-way SYNTH Forge, and forging is completely voluntary. Keeping your VCLM and CHONX forever is fully supported.

**When it unlocks.** The Forge opens on Base permanently once 100,000,000 lifetime CHONX have been minted on Base. Until then, the Forge refuses every forge request.

**Steps:**

1. Connect your wallet and confirm your wallet is on Base.
2. Open the Forge page and choose how many SYNTH to forge. The Forge function `forge(uint256 count)` accepts whole numbers of SYNTH (1, 2, 3, and so on); fractional SYNTH forging is not possible.
3. Approve the Forge contract to burn 1,000 VCLM and 10,000 CHONX for each SYNTH. Check the Forge address against Section 10.
4. Confirm the forge. The VCLM and CHONX are permanently burned and the SYNTH is minted to your wallet.

The Forge has no reversal, redemption, or restore path. Burned tokens never restore any lifetime issuance cap. The SYNTH token and the Forge are the same contract, so the SYNTH token address is the Forge address.

## 9. Complete Numbers and Formulas Sheet

Every value below can be recomputed by you or your AI. Requirement IDs such as VF-COM-017 refer to Master Specification Revision 21.

### 9.1 Protocol Tokens and Lifetime Caps on Base

| Token | Lifetime hard cap on Base | Available | Created by |
|---|---|---|---|
| VCLM | 10,000,000,000 | From launch | Verified locks and stake reward epochs |
| CHONX | 100,000,000,000 | After 10,000,000 lifetime VCLM on Base | Verified locks after unlock |
| SYNTH | 10,000,000 | Forge opens after 100,000,000 lifetime CHONX on Base | Forge, burning 1,000 VCLM + 10,000 CHONX each |

- All three tokens use 18 decimals (VF-TOK-001).
- The Base protocol tokens started at a total supply of zero, with no pre-minted tokens and no pre-existing supply.
- Caps, supplies, and unlock counters are counted on Base.
- Lifetime VCLM counts both lock issuance and stake reward VCLM, and both draw from the same 10,000,000,000 cap (VF-SUP-002). The CHONX unlock counter uses that same lifetime figure.
- Burning reduces circulating supply but never reduces lifetime issuance or restores cap room (VF-SUP-003).
- The protocol tokens on Base use the symbols VCLM, CHONX, and SYNTH.
- The protocol imposes no transfer tax, freeze list, allowlist, or trading restriction on any protocol token (VF-TOK-013).

### 9.2 Emission Rates and Step-Down Schedule

| Output | Starting rate | Permanent floor | Step-down |
|---|---|---|---|
| VCLM | 10 VCLM per $1.00 | 1 VCLM per $1.00 | Rate x 0.98333 after each complete 30-day period |
| CHONX | 100 CHONX per $1.00 | 10 CHONX per $1.00 | Rate x 0.98333 after each complete 30-day period |

Current rate = max(starting rate x 0.98333^n, floor), where n is the number of complete 30-day periods. The multiplication is applied once per period with each result rounded down at 18 decimals, exactly as the Verifier computes it. A partial 30-day period does not count. Asset and duration multipliers never change this schedule.

The contract counts n as floor(whole days since the Base launch / 30), using the lock's creation time on Base.

| Period n | Days since launch | VCLM per $1.00 | CHONX per $1.00 |
|---|---|---|---|
| 0 | 0 to 29 | 10.000000 | 100.000000 |
| 1 | 30 | 9.833300 | 98.333000 |
| 2 | 60 | 9.669378 | 96.693788 |
| 3 | 90 | 9.508190 | 95.081903 |
| 6 | 180 | 9.040568 | 90.405683 |
| 12 | 360 | 8.173187 | 81.731876 |
| 24 | 720 | 6.680099 | 66.800995 |
| 36 | 1,080 | 5.459770 | 54.597707 |
| 60 | 1,800 | 3.647181 | 36.471812 |
| 100 | 3,000 | 1.861782 | 18.617823 |
| 120 | 3,600 | 1.330193 | 13.301930 |
| 136 | 4,080 | 1.016490 | 10.164904 |
| 137 and later | 4,110 and later | 1.000000 | 10.000000 |

Values are shown truncated to six decimals. The floor is reached at period 137, which is 4,110 days after launch.

**Both clocks start at launch.** On the live contracts, VCLM and CHONX both count their 30-day periods from the Base launch time. Section 13 explains what that means when CHONX unlocks.

### 9.3 The 16 Commitment Vault Lock Durations

| Duration | Seconds | Role | Duration multiplier |
|---|---|---|---|
| 1 hour | 3,600 | Trust-Building Handshake | 1.0x |
| 7 days | 604,800 | Shortest standard lock | 1.0x |
| 30 days | 2,592,000 | Short lock | 1.15x |
| 60 days | 5,184,000 | Short to medium lock | 1.3x |
| 90 days | 7,776,000 | Medium lock | 1.5x |
| 180 days | 15,552,000 | Six-month lock | 2.0x |
| 365 days | 31,536,000 | One-year lock | 2.5x |
| 730 days | 63,072,000 | Two-year lock | 3.8x |
| 1,095 days | 94,608,000 | Three-year lock | 5.0x |
| 1,460 days | 126,144,000 | Four-year lock | 5.75x |
| 1,825 days | 157,680,000 | Five-year lock | 6.5x |
| 2,190 days | 189,216,000 | Six-year lock | 6.8x |
| 2,555 days | 220,752,000 | Seven-year lock | 7.1x |
| 2,920 days | 252,288,000 | Eight-year lock | 7.4x |
| 3,285 days | 283,824,000 | Nine-year lock | 7.7x |
| 3,650 days | 315,360,000 | Ten-year lock | 8.0x |

Exclusively these 16 durations are accepted. No in-between duration or blended multiplier exists (VF-COM-001, VF-COM-002). The 1-hour duration is accepted solely as a Handshake worth $0.01 to $0.02.

### 9.4 Asset Classes and Class Multipliers

Asset class affects lock issuance alone. It never affects stake weight (VF-REG-007). Classes reflect practical simplicity under fixed rules and are never a judgment on any token or community.

| Class | Multiplier |
|---|---|
| S1 | 1.5x |
| S2 | 1.3x |
| S3 | 1.0x |

**Base (chain 8453): 2,893 approved registry entries, Registry Revision E.**

| Class | Entries |
|---|---|
| S1 | Base USDC issued by Circle, registry row 454, `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| S2 | Native ETH on Base, registry row 2 |
| S3 | All other 2,891 entries, including the bridged USDT at row 1086 and WETH |

- Registry entries were admitted through automated lock and release compatibility testing, not market-cap screening. Explicit team registry overrides, such as TigerOG on Base, are disclosed in the specification.
- The Base registry was fixed at deployment and cannot be added to, removed from, or reclassified (VF-REG-010).
- VCLM, CHONX, and SYNTH can never be locked (VF-TOK-007).
- **Stablecoin price rule:** for the exact stablecoin identities listed for Base, a last posted price below $0.95 marks that asset unusable for new lock valuation and minting. Exactly $0.95 is allowed (VF-ORC-015).

### 9.5 Issuance Formula, Calculation Order, and Rounding

**Output = Verified Gross USD Value x current emission rate x asset multiplier x duration multiplier**

- **Gross basis.** Issuance is calculated on 100% of the Verified Gross USD Value, before the 5% lock fee is taken out (VF-COM-017). The fee is paid separately and does not reduce the issuance basis.
- **Valuation.** Verified Gross USD Value = floor(gross token units x posted price / 10^(token decimals + 12)), where the posted price is USD per whole token with 30 decimals. This gives USD with 18 decimals, rounded down once (VF-ORC-016).
- **Order.** Gross USD value, then emission rate, then asset multiplier, then duration multiplier, then the output token's smallest units (VF-COM-018).
- **Rounding.** Every integer division rounds down. No factor may be reordered or rounded to the nearest unit (VF-COM-019).
- **Price kept per lock.** The posted price in effect when your lock is created stays with that lock. A delay in verification never reprices it (VF-ORC-009, VF-ORC-010).

**Worked example 1, an S3 token for one year at period 0:**
$100.00 gross value x 10 VCLM per $1.00 x 1.0 x 2.5 = 2,500 VCLM.

**Worked example 2, a Base USDC Handshake:**
0.015 USDC, which is 15,000 units at 6 decimals, posted at $1.00, gives a gross value of $0.015. Output = $0.015 x 10 x 1.5 x 1.0 = 0.225 VCLM.

### 9.6 The 5% Lock Fee and the 95% Principal

- Fee units = floor(gross units x 500 / 10,000). The fee rate is 500 basis points, which is 5.00%, on every duration including the Handshake (VF-COM-004, VF-COM-009, VF-COM-011).
- Principal units = gross units minus fee units (VF-COM-012).
- If rounding would make either the fee or the principal zero, the lock is refused before anything moves (VF-COM-013).
- 100% of the fee goes to the one fixed Dev Fund address on Base, in the same token, with no swap, conversion, bridge, or split (VF-FEE-001, VF-FEE-002).
- Principal never goes to the Dev Fund (VF-FEE-003).
- For a rebasing ERC-20 whose vault balance falls below total owed principal, release pays each open lock a pro-rata share of its recorded principal (see Section 12).
- A fee that has been transferred is permanently non-refundable (VF-COM-015, VF-FEE-011).

**Worked example from Section 9.5, example 2:** 15,000 USDC units gross. Fee = floor(15,000 x 500 / 10,000) = 750 units, which is 0.00075 USDC. Principal = 14,250 units, which is 0.01425 USDC, released at maturity.

### 9.7 Reward-Accounting Credits and Epoch Reward VCLM

Each verified lock fee records a one-time Reward-Accounting Credit. The credit is a pure on-chain accounting number. It is never a deposit, a pool, an asset balance, or a claim on Dev Fund assets, and it cannot be withdrawn (VF-RAC-007).

- Reward-Accounting Credit = Verified USD Fee Value x 60%
- Epoch Reward Basis = sum of the credits recorded in that 10-day epoch
- Epoch Reward VCLM = Epoch Reward Basis / $0.10

The $0.10 Reward Reference Value is a permanent internal constant, not a market price (VF-RAC-005). In plain terms, every $1.00 of verified lock fee adds 6 VCLM to the epoch's reward pool. Section 2.3 explains why this number is fixed. The full Epoch Reward VCLM is newly minted from the Base VCLM lifetime cap and allocated to eligible stakes in proportion to their weight.

**Worked example:** a $100.00 lock has a Verified USD Fee Value of $5.00. Its credit is $5.00 x 60% = $3.00, which adds $3.00 / $0.10 = 30 VCLM to the reward for the epoch in which the credit was recorded.

- If an epoch has no eligible stake weight, it mints nothing, closes, and carries nothing forward (VF-STK-015).
- Each stake's share is rounded down to the smallest VCLM unit. A microscopic remainder stays in the Stake contract and is never reused (VF-STK-026, VF-STK-027).

### 9.8 Treasury Reward Stake Weight

**Weight = staked amount x token multiplier x staking duration multiplier**

| Token | Token multiplier |
|---|---|
| VCLM | 1.0x |
| CHONX | 2.0x |
| SYNTH | 4.0x |

| Term | Seconds | Duration multiplier |
|---|---|---|
| 30 days | 2,592,000 | 1.0x |
| 60 days | 5,184,000 | 1.4x |
| 90 days | 7,776,000 | 1.75x |
| 120 days | 10,368,000 | 2.1x |

**Worked examples:** 1,000 VCLM staked for 120 days has a weight of 1,000 x 1.0 x 2.1 = 2,100. 1,000 CHONX staked for 90 days has a weight of 1,000 x 2.0 x 1.75 = 3,500. Your share of an epoch's reward VCLM is your weight divided by the total eligible weight for that epoch.

### 9.9 Fixed 10-Day Epochs and the N and N+1 Rule

- The Base launch time defines T0. Epoch N runs from T0 + (N minus 1) x 10 days up to, but not including, T0 + N x 10 days. Activity at the exact ending second belongs to the next epoch (Section 10.2 of the specification).
- Epoch boundaries never move, even if closing an epoch is submitted late (VF-STK-009).
- **Qualifying for epoch N:** your stake must be active at the exact start of epoch N, stay active through all of epoch N, and stay active through the scheduled end of epoch N+1 (VF-STK-011, VF-STK-012).
- **When it becomes claimable:** an epoch's reward is fixed after the end of epoch N+1, once the epoch has been closed and allocated (VF-STK-013).

**Worked example:** suppose you open a 30-day stake 35 days after T0, which is partway through epoch 4. The next epoch to start is epoch 5, at day 40. Your stake ends at day 65. Epoch 5 qualifies, because epoch 6 ends at day 60, before day 65. Epoch 6 does not qualify, because epoch 7 ends at day 70, after your stake ends. If you had opened the same stake exactly at day 40, it would end at day 70 and qualify for epochs 5 and 6. Queuing an extension before your term ends keeps the stake continuously active, so later epochs can qualify as well.

### 9.10 Queued Extension Rules

- One future term of 30, 60, 90, or 120 days may be queued while the stake is active (VF-STK-021).
- It begins at the scheduled end of the current term, and the current multiplier is unchanged until then (VF-STK-022).
- One queued term at a time. After it begins, another may be queued (VF-STK-023).
- Queuing adds or removes no tokens and charges no fee (VF-STK-024).
- Without a queued term, the stake becomes inactive at maturity and cannot cover a gap afterward (VF-STK-025).

### 9.11 Lifetime Cap Behavior and the Terminal State

- Remaining lifetime capacity = hard cap minus cumulative lifetime issuance on Base.
- A lock whose full calculated output would exceed remaining capacity is refused in full. No partial or substitute output is ever issued (VF-SUP-005, VF-SUP-006). Your principal still releases at maturity.
- An epoch reward that would exceed remaining VCLM capacity mints nothing, closes, and marks its credits used. A later, smaller epoch reward may still fit (VF-STK-028, VF-SUP-010).
- When remaining VCLM capacity on Base reaches zero, Treasury Reward Stake on Base permanently closes to new stakes and extensions. All existing staked tokens become withdrawable at once, and any claimable VCLM already recorded stays available (VF-STK-029, VF-STK-030).
- After that point, lock fees create no new Reward-Accounting Credits (VF-RAC-008).

### 9.12 Launch Time, Epochs, and Periods on Base

All times are Eastern Time. Launch time is the Base Verifier's `protocolLaunchTimestamp`, which the Stake contract uses as T0.

| Chain | Launch (Unix) | Launch (ET) | Epoch 1 ends | Period 1 starts |
|---|---|---|---|---|
| Base | 1793150013 | Oct 27, 2026, 9:13:33 PM | Nov 6, 2026, 8:13:33 PM | Nov 26, 2026, 8:13:33 PM |

The one-hour shift in the clock time after launch reflects the end of daylight saving time on November 1, 2026. The underlying intervals are exactly 10 days and 30 days in seconds.

## 10. Verified Live Contract Directory

Every contract below was deployed, finalized, and source-verified. The 7 Base contracts were recompiled from their published source with solc 0.8.19 (optimizer 200 runs, viaIR, EVM version paris) and matched the on-chain bytecode exactly, including the metadata hash.

**Verified source locations:**

- **Base:** BaseScan and Sourcify. Explorer link format: `https://basescan.org/address/<address>#code`
- **Sourcify:** `https://repo.sourcify.dev/8453/<address>`

### 10.1 Base (Chain ID 8453)

| Contract | Address |
|---|---|
| Commitment Vault Lock | `0xc3c5c03C220A31AA7DeF397304F0d3ddBB0C8E30` |
| Commitment Vault Verifier | `0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2` |
| Lock Reader | `0xF3c9b227983032487493F2a7F00021E1962699Cb` |
| Treasury Reward Stake | `0x7E7110a10f334A11a9357E37DbAB0a2EaA540A15` |
| SYNTH Forge and SYNTH token | `0x7EA77794c2702e5E810f3BCd2046e52c1B04ff3f` |
| VCLM token | `0x3b7fbD76467559445d309B355Dc158C82979F0EF` |
| CHONX token | `0xD5c233372D086fA94120053E2E17Da88fba48a34` |
| Dev Fund (fee destination) | `0xFD21BF773A193CDcb9F793100CB13a8baAdc3e9a` |
| Scheduled price poster | `0x60013cD1aF9e81B083aa13eCDe5F491771db0DB4` |

**Why there is no separate SYNTH address.** The Forge contract is itself the SYNTH token. It mints SYNTH when you forge, and it is the address your wallet uses to hold and transfer SYNTH. The Lock and Stake contracts on Base both point to this same address as the SYNTH token.

### 10.2 Checklist: Confirm On-Chain That There Is No Contract Owner, Upgrade, or Rule-Change Key

These are free read calls that need no wallet. Use the explorer's Read Contract tab, any public RPC, or ask your AI to perform them.

| Contract | Read function | Expected result |
|---|---|---|
| Verifier | `deployer()` | `0x0000000000000000000000000000000000000000` |
| Verifier | `configurationFinalized()` | `true` |
| Verifier | `scheduledPricePoster()` | The price poster address in Section 10 |
| VCLM token | `deployer()` | `0x0000000000000000000000000000000000000000` |
| VCLM token | `finalized()` | `true` |
| VCLM token | `minterVerifier()` and `minterStake()` | The Verifier and Stake addresses |
| CHONX token | `deployer()` | `0x0000000000000000000000000000000000000000` |
| CHONX token | `finalized()` | `true` |
| CHONX token | `minterVerifier()` and `minterStake()` | The Verifier address, and the zero address |
| Lock | `devFund()` | The Dev Fund address in Section 10 |
| Lock | `synthToken()` | The Forge address |

**What to look for in the source:**

1. **No proxy.** Each address holds its full contract code directly. There is no delegatecall-based upgrade pattern and no implementation slot.
2. **No owner drain.** Search the Lock source for every transfer of tokens out of the contract. The fee is sent to the immutable `devFund` during lock creation, and principal is sent solely through `release`, which requires the maturity time to have passed and the caller to be the release wallet recorded for that lock.
3. **No protocol pause button on releases, stakes, withdrawals, or claims.** No function pauses them. Per-asset price usability for new lock valuation is covered in Section 11.
4. **No team mint.** The token `mint` function accepts calls solely from the two minter contracts set once in `initialize`, which cannot be called again.
5. **Deployment-time functions are closed.** In the Verifier source, search for the deployment-period modifier, which contains the text `DuringDeployment`. Every function guarded by it requires the deployer role and an unfinalized configuration, so none of them can ever run again.
6. **Price poster scope.** The price poster can call solely `applyScheduledPriceRun` on the Verifier. That function requires run IDs in strict order and marks any asset with a failed lookup as unusable.

**Snapshot of these reads.** On November 6, 2026, at about 1:50 PM ET, these reads were taken from a public RPC endpoint on Base. On Base, every listed contract had deployed code, `deployer()` read as the zero address on the Verifier, VCLM, and CHONX, `configurationFinalized()` and `finalized()` read as true, the minters matched the table above, `devFund()` matched Section 10, CHONX supply was zero, SYNTH supply was zero, and the Stake contract was in epoch 1. VCLM supply was already above zero: Live verification Handshakes and pre-announcement team Commitment Vault Locks are already on-chain. They paid the same 5% Dev Fund fee and minted VCLM under the exact same public rules. Run the reads yourself rather than relying on this snapshot.

## 11. How Prices Work, What the Price Poster Can and Cannot Do, and What Your AI Can Check

Smart contracts cannot fetch CoinGecko or DexScreener on their own. So the Base Verifier accepts scheduled price runs from one fixed address, the `scheduledPricePoster`. That address was set during deployment, and the function that sets it can never run again after `finalize()`. Nobody can swap in a different poster address, including the team.

### 11.1 Your Principal Is Independent of the Price Poster

Releasing your 95% locked tokens at maturity never reads a price and never calls the Verifier. Even if the price poster stopped posting forever, every lock would still release at its maturity time to its recorded release wallet (VF-PRI-004, VF-PRI-005).

**What the price poster can do:** call `applyScheduledPriceRun` on the Verifier to post USD values used to value new locks, and mark an individual asset unusable in a run.

**What the price poster cannot do:** move, hold, or release anyone's principal; change any rule, fee, multiplier, cap, duration, or Dev Fund address; mint any token; or reprice a lock that already exists.

### 11.2 Current Schedule and Price Rules

- **Schedule.** The team sets the price schedule in the price job. At launch it runs once every 4 days. The team may change the schedule, and the official app cannot (VF-ORC-001).
- **Sources.** For each approved asset, the job takes the earliest valid price from an ordered cascade: a CoinGecko lookup by the configured ID, then a DexScreener lookup by exact contract. A lookup by ticker symbol alone is never used.
- **No substitute price.** No hardcoded or invented price is ever used. If a run produces no valid price for an asset, the run marks that asset unusable for new lock valuation and VCLM or CHONX minting until a later successful run. The official app does not offer a new lock on that token, while a hand-built lock transaction still routes the 5% fee and holds 95% principal and then cannot verify or mint until a usable price exists (see Section 11.6; VF-ORC-004, VF-ORC-005, VF-ORC-008).
- **No on-chain age limit.** A posted price stays in effect until the next scheduled run for that asset. At the 4-day launch schedule, a price can be up to about 4 days old when you lock, or older if a scheduled run is delayed. The app shows the exact posted price and its posting time before you sign, so you can accept it or walk away (VF-ORC-017).

### 11.3 Thin Tokens and Brief Price Spikes

Some approved tokens trade in small pools where the price can jump briefly. The design limits what that can do:

- Anyone trying to use a high posted price still has to send 5% of a real token stack permanently to the Dev Fund and time-lock the other 95% for the chosen duration.
- No price, high or low, can touch anyone else's locked principal.
- Every lock's output still has to fit inside the fixed lifetime cap on Base.
- The Verifier lets each scheduled run mark an individual asset as `usable = false`. That marks that asset unusable for new lock valuation and VCLM or CHONX minting until a later successful run. The official app does not offer a new lock on that token, while a hand-built lock transaction still routes the 5% fee and holds 95% principal and then cannot verify or mint until a usable price exists (see Section 11.6). It never affects locks that already exist.

We state the remaining limit plainly: a posted price that is briefly too high could let a lock mint more VCLM than the token's usual value would, which adds to supply. That is the reason the team intends to publish the price rules for anyone to check.

### 11.4 Glass-Box Price Rules

The price-fetching rules, meaning the lookup logic without any signing key, are published in the `price-fetcher` folder of the Vinculum public verification repository, alongside the contract files, with its plain-English guide, tests, and the Base registry it is built from. Anyone, or their AI, can inspect the exact cascade, run the same lookups against the live CoinGecko and DexScreener APIs, and compare results with the `scheduledPrices` values stored on-chain. Any change to the price rules is recorded in the Master Specification. The signing key and the running job itself stay private.

### 11.5 What Your AI Can and Cannot Verify

**On-chain:** the price record stored in the Verifier for each asset, readable through `scheduledPrices` with the asset's key, which holds the posted USD price at 30 decimals and whether it is usable; the price bound to each lock through `lockReferencePrices`; the poster address through `scheduledPricePoster()`; and the fact that the poster can call nothing except `applyScheduledPriceRun`.

**Off-chain:** whether the posted figure matches what CoinGecko or DexScreener reported at fetch time. Your AI can compare the posted price with public data for the same time and, once the price rules are published, check it against those rules.

### 11.6 A Lock Built Outside the Official App

The official app runs every available check before it builds a transaction, including whether a usable price exists. A transaction built by hand can skip those checks. If it creates a lock that cannot be verified, the 5% lock fee is still non-refundable and no VCLM or CHONX is issued, but the principal still releases at maturity (VF-COM-015).

## 12. Honest Limits and Non-Promises

Please read these before you lock anything beyond a Handshake.

- **No early unlock.** Locked principal cannot be released before maturity for any reason. There is no cancellation, penalty exit, or emergency release.
- **The 5% lock fee is non-refundable.** Once transferred to the Dev Fund, it cannot be sent back, including for a hand-built transaction that the protocol does not recognize.
- **No promises about protocol tokens.** VCLM, CHONX, and SYNTH carry no promise of any market price, liquidity, exchange listing, redemption right, or financial outcome. Protocol reference values such as $0.10 per VCLM are issuance references, not prices.
- **95% of the token quantity, not a dollar value.** For ordinary ERC-20 and native locks, maturity sends the recorded 95% principal quantity back to the release wallet. If a rebasing ERC-20's vault balance falls below total owed principal, each open lock of that token receives a pro-rata share (`principal * balance / owedPrincipal`) so no lock is paid from another lock's principal; any positive rebase surplus stays in the vault. Their dollar value at that time depends on the market for that token.
- **Rewards are newly minted tokens.** Stake rewards and lock issuance are newly minted protocol tokens. No outside assets back them, and more issuance adds to supply.
- **Issuance can be refused.** If no usable price exists, or the output would exceed the remaining lifetime cap, no VCLM or CHONX is issued. Your principal still releases at maturity.
- **Scheduled prices, not live prices.** Prices are posted on the team's schedule, not on every block, as described in Section 11.
- **Contracts cannot be patched.** Removing every contract owner, upgrade, and rule-change key means a defect in deployed logic cannot be repaired in place. The team accepted that consequence on purpose (VF-IMM-006).
- **Testing, and what it is not.** The contracts went through extensive testing by the team, including automated test suites, test network runs, live small-value Handshake verification on Base, and AI red teaming. The contracts have not undergone a third-party external security review by an outside firm. Read the code, ask your AI, run a Handshake, and decide for yourself.

## 13. How the CHONX Rate Clock Works on the Live Contracts

On Base, the deployed Verifier measures the 30-day step-down schedule for both VCLM and CHONX from the Base protocol launch timestamp. CHONX itself stays locked until 10,000,000 lifetime VCLM have been minted on Base. The written text of VF-TOK-008 is updated in Master Specification Revision 22 to match this live behavior.

Two things are true at once:

- **Per dollar at unlock.** If several 30-day periods pass before 10,000,000 lifetime VCLM are minted, CHONX opens at that period's stepped-down rate rather than at 100 CHONX per $1.00. For example, if CHONX unlocks during period 6, new CHONX locks start at 90.405683 CHONX per $1.00. During period 12 the figure is 81.731876. From there, the rate keeps stepping down on the same schedule as VCLM until the floor of 10 CHONX per $1.00.
- **Community momentum.** Because the clock runs from launch, if the community reaches 10,000,000 VCLM sooner, CHONX opens at a starting rate closer to 100 per $1.00. The fixed 100,000,000 lifetime CHONX threshold that opens the SYNTH Forge does not move.
- **Practical math toward SYNTH.** In plain math, if CHONX unlocks in a later 30-day period at a stepped-down per-dollar rate, reaching 100,000,000 lifetime CHONX to open the SYNTH Forge requires proportionally more cumulative USD lock volume. For example, at the period 6 rate of 90.405683 CHONX per $1.00, the same 100,000,000 CHONX takes about 10.6% more verified USD lock volume than it would at 100 CHONX per $1.00, with all multipliers held equal.

Your AI can confirm this directly: in the Verifier source, `_computeEmissionRate` receives the days since launch for both output tokens. CHONX has not yet unlocked on Base, so no CHONX has been issued on Base.

## 14. Short Glossary

| Term | Meaning |
|---|---|
| Commitment Vault Lock | A single, fixed-term, non-renewable lock of an approved token on Base |
| Trust-Building Handshake | A 1-hour lock worth $0.01 to $0.02 |
| Verified Gross USD Value | The USD value of the full amount you lock, before the 5% lock fee, at the posted price |
| Dev Fund | The one fixed address on Base that receives every lock fee |
| Principal | The 95% of your locked tokens held until maturity |
| Release wallet | The wallet you set at lock time that alone can release the principal |
| Reward-Accounting Credit | An on-chain accounting number equal to 60% of a lock's verified USD fee value |
| Epoch | A fixed 10-day interval measured from the Base launch |
| Stake weight | Staked amount x token multiplier x duration multiplier |
| Treasury Reward Stake | The staking mechanism, implemented in the `VinculumFinalisStake` contract; Treasury means the unminted issuance reserve under the fixed cap |
| Price poster | The one fixed address on Base that can post scheduled price runs to the Verifier |
| Terminal state | The permanent state after the Base VCLM lifetime cap is reached |

## Document Control

| Item | Value |
|---|---|
| Document | Vinculum Protocol User's Manual, AI-Ready Companion Edition |
| Edition | Public Release Candidate (Draft 3 Base-only review), November 8, 2026 |
| Governing specification | Vinculum Finalis Master Specification Revision 21, November 1, 2026 (Revision 22 aligns the VF-TOK-008 text with the live CHONX rate clock described in Section 13) |
| Specification SHA-256 | `c0cab7e43f3f59b5a8f8e61813842dd1e9c653a0b9b91315ec5dd1c9970a9f53` |
| Companion document | Vinculum Protocol White Paper, Public Release Candidate (Draft 3 Base-only review), November 8, 2026 |
| Address sources | The Base deployment record and the bytecode match record, checked against live chain reads on November 6, 2026 |
