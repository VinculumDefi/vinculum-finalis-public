# How to verify the Vinculum contracts on Base

This guide is for anyone who wants to check that the Solidity files in this repository are the same source BaseScan has already verified for the live Vinculum contracts on Base. You do not need to trust the team. Every step uses public pages and the files in this folder.

Vinculum is live on Base only. VCLM, CHONX and SYNTH are tokens on Base.

## The live contracts on Base

Each contract below is shown on BaseScan as source code verified, with an exact match. The file names in the `base/` folder are plain names so they are easy to read. On BaseScan, the same source appears under the original compiler paths listed here. Compare the Solidity text, not the file names.

### Lock

- Solidity name: `BaseCommitmentVaultLock`
- File in this folder: `base/Base-Lock-Contract.sol`
- Also used by this contract: `base/Base-Commitment-Durations.sol`
- Original paths on BaseScan: `contracts/BaseCommitmentVaultLock.sol` and `contracts/CommitmentDurations.sol`
- Address: `0xc3c5c03C220A31AA7DeF397304F0d3ddBB0C8E30`
- BaseScan: https://basescan.org/address/0xc3c5c03C220A31AA7DeF397304F0d3ddBB0C8E30#code

### VCLM token

- Solidity name: `VinculumFinalisToken`
- File in this folder: `base/Base-Token-Contract.sol`
- Original path on BaseScan: `contracts/VinculumFinalisToken.sol`
- Address: `0x3b7fbD76467559445d309B355Dc158C82979F0EF`
- BaseScan: https://basescan.org/address/0x3b7fbD76467559445d309B355Dc158C82979F0EF#code

### CHONX token

- Solidity name: `VinculumFinalisToken`
- File in this folder: `base/Base-Token-Contract.sol` (the same source as VCLM)
- Original path on BaseScan: `contracts/VinculumFinalisToken.sol`
- Address: `0xD5c233372D086fA94120053E2E17Da88fba48a34`
- BaseScan: https://basescan.org/address/0xD5c233372D086fA94120053E2E17Da88fba48a34#code

VCLM and CHONX were both deployed from the same token source. The two deployments differ only in the name, symbol and hard cap that were passed in at creation. Those values are shown in the constructor arguments on each BaseScan page.

### Verifier

- Solidity name: `VinculumFinalisVerifier`
- File in this folder: `base/Base-Verifier-Contract.sol`
- Also used by this contract: `base/Base-Commitment-Durations.sol`
- Original paths on BaseScan: `contracts/VinculumFinalisVerifier.sol` and `contracts/CommitmentDurations.sol`
- Address: `0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2`
- BaseScan: https://basescan.org/address/0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2#code

### Forge (SYNTH token on Base)

- Solidity name: `VinculumFinalisSynth`
- File in this folder: `base/Base-Forge-Contract.sol`
- Original path on BaseScan: `contracts/VinculumFinalisSynth.sol`
- Address: `0x7EA77794c2702e5E810f3BCd2046e52c1B04ff3f`
- BaseScan: https://basescan.org/address/0x7EA77794c2702e5E810f3BCd2046e52c1B04ff3f#code

### Stake

- Solidity name: `VinculumFinalisStake`
- File in this folder: `base/Base-Stake-Contract.sol`
- Original path on BaseScan: `contracts/VinculumFinalisStake.sol`
- Address: `0x7E7110a10f334A11a9357E37DbAB0a2EaA540A15`
- BaseScan: https://basescan.org/address/0x7E7110a10f334A11a9357E37DbAB0a2EaA540A15#code

### Reader

- Solidity name: `BaseLockRecordVerifier`
- File in this folder: `base/Base-Reader-Contract.sol`
- Original path on BaseScan: `contracts/chain-verifiers/BaseLockRecordVerifier.sol`
- Address: `0xF3c9b227983032487493F2a7F00021E1962699Cb`
- BaseScan: https://basescan.org/address/0xF3c9b227983032487493F2a7F00021E1962699Cb#code

The price poster at `0x60013cD1aF9e81B083aa13eCDe5F491771db0DB4` and the Dev Fund at `0xFD21BF773A193CDcb9F793100CB13a8baAdc3e9a` are wallets. They have no contract code, so there is no source to compare.

## How to compare the source

1. Open the BaseScan link for a contract. Go to the Contract tab. Confirm the page says the source is verified as an exact match.
2. Open the matching file in `base/` in this repository.
3. Compare the Solidity text on BaseScan with the file here. The text should match. The file name may differ, as explained above.
4. If a contract lists more than one file on BaseScan (the lock and the verifier both include Commitment Durations), compare those files too.

BaseScan also shows the compiler as `v0.8.19+commit.7dd6d404`, with optimization enabled at 200 runs and the default EVM version.

## A prompt you can paste into your own AI

Copy the text below and paste it into any AI assistant, along with the files from this repository or a link to it.

> Please review the Vinculum Protocol contracts on Base using the files in this repository and the public BaseScan pages. Treat this as a check of the team's claims, not a request to take them on trust.
>
> The live contracts on Base are:
> - Lock (BaseCommitmentVaultLock) at 0xc3c5c03C220A31AA7DeF397304F0d3ddBB0C8E30, file base/Base-Lock-Contract.sol plus base/Base-Commitment-Durations.sol
> - VCLM token (VinculumFinalisToken) at 0x3b7fbD76467559445d309B355Dc158C82979F0EF, file base/Base-Token-Contract.sol
> - CHONX token (VinculumFinalisToken) at 0xD5c233372D086fA94120053E2E17Da88fba48a34, same file base/Base-Token-Contract.sol
> - Verifier (VinculumFinalisVerifier) at 0x6857Ca0909716e5aD4f4DEc3cd004C73986F6FD2, file base/Base-Verifier-Contract.sol plus base/Base-Commitment-Durations.sol
> - Forge / SYNTH (VinculumFinalisSynth) at 0x7EA77794c2702e5E810f3BCd2046e52c1B04ff3f, file base/Base-Forge-Contract.sol
> - Stake (VinculumFinalisStake) at 0x7E7110a10f334A11a9357E37DbAB0a2EaA540A15, file base/Base-Stake-Contract.sol
> - Reader (BaseLockRecordVerifier) at 0xF3c9b227983032487493F2a7F00021E1962699Cb, file base/Base-Reader-Contract.sol
>
> For each contract, please check:
> 1. Does the Solidity text in this repository match the verified source on the BaseScan Contract tab for that exact address? The file names here are plain names for reading. On BaseScan the original compiler paths are used, so compare the text, not the file names.
> 2. Does BaseScan show the source as verified with an exact match?
> 3. Is there any owner, admin, pause, upgrade or proxy pattern that can still be used after finalize?
> 4. What can the scheduled price poster address do, and what can it not do?
> 5. When someone locks a supported token on Base, or native ETH on Base, where does the 5% fee go, and how much comes back at release?
> 6. What happens on a lock if no usable price is posted?
> 7. Does staking charge any fee?
>
> Quote the exact function names and lines you rely on, and tell me anything you could not confirm.

If something does not match, we want to know.
