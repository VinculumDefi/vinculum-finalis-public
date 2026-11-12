// =============================================================================
// VinculumFinalisVerifier — Canonical Base-Side Verification & Minting Contract
//
// PROVENANCE: Built directly from Revision 6 authoritative documents:
//   - 227826f11_Vinculum_Finalis_Master_Specification_Revision_6_2026-07-28.docx (Revision 6)
//   - Vinculum_Finalis_Protocol_Constants.json (Revision 6, 2026-07-28)
//   - Vinculum_Finalis_Architecture_Design.md (Sections A.9, A.11-A.16, B.3, D, P)
//   - Vinculum_Finalis_Governing_Requirements.json (209 requirements)
//   - Vinculum_Finalis_Requirement_Traceability.csv
//
// Governing source SHA-256: 5a9350618d81005d53b4d05628e7403e8c39fe63847a46576a5fadfbd4ef0bf9
//
// This contract is the Base-chain recognition boundary (BASE-VERIFY).
// It accepts a normalized ProofPackage from ANY source environment and performs
// the complete protocol verification before authorizing issuance.
//
// Chain-agnostic design: the same verifyAndMint() function handles Solana,
// XRPL, Cosmos, Bitcoin, Stellar, EVM, and all 17 supported environments.
// Per-environment finality proof verification is dispatched to IChainVerifier
// implementations (DESIGN DEFINED — DEPLOYABILITY EVIDENCE REQUIRED per Section O).
//
// Requirements implemented:
//   VF-XCH-006/010: Source finality gate
//   VF-XCH-011:     Immutable-facts validation
//   VF-XCH-013:     Replay protection (env + lock id)
//   VF-COM-001/002: Permitted durations only
//   VF-COM-003/009: USD value bounds
//   VF-COM-006:     Rev 12: no Handshake allowance; handshakeAllowanceCount is ignored
//   VF-COM-011-013: Fee math (floor, principal=gross-fee, zero rejection)
//   VF-COM-017-020: Issuance calculation (fixed order, floor)
//   VF-COM-025:     CHONX activation-at-creation (causal receipt)
//   VF-ARC-006:     Nonzero Base recipient
//   VF-REG-001:     Approved asset registry
//   VF-FEE-004/009: Dev Fund destination
//   VF-TOK-002:     CHONX activation threshold
//   VF-TOK-007:     Protocol tokens prohibited as inputs
//   VF-SUP-015:     Hard-cap rejection in full
//   VF-RAC-001:     RAC exact-once (immutable-facts key)
//
// SPDX-License-Identifier: PROTOCOL-RESTRICTED
// Solidity 0.8.19+
// =============================================================================

pragma solidity 0.8.19;

import "./CommitmentDurations.sol";

// ---------------------------------------------------------------------------
// Interfaces for per-environment finality verifiers (Section O)
// Each environment provides its own verifier contract implementing this
// interface. BASE-VERIFY dispatches to the correct verifier based on
// sourceEnvironmentId. These are DESIGN DEFINED — DEPLOYABILITY EVIDENCE
// REQUIRED until each environment's verifier is deployed and proven.
// ---------------------------------------------------------------------------

interface IChainVerifier {
    /// @notice Verifies that the source finality proof is valid and the
    ///         source event is finalized according to the environment's
    ///         finality rule.
    /// @param lockEventProof The chain-specific lock event proof
    /// @param sourceFinalityProof The chain-specific finality proof
    /// @return finalized Whether the source event is finalized
    /// @return sourceBlockHash The finalized source block hash
    /// @return sourceBlockHeight The finalized source block height
    function verifyFinality(
        bytes calldata lockEventProof,
        bytes calldata sourceFinalityProof
    ) external view returns (bool finalized, bytes32 sourceBlockHash, uint256 sourceBlockHeight);

    /// @notice Extracts the immutable facts from the lock event proof.
    /// @return lockId The unique commitment vault lock identifier
    /// @return grossAmount The gross asset amount in smallest units
    /// @return feeAmount The actual fee amount in smallest units
    /// @return principalAmount The principal amount in smallest units
    /// @return durationSecs The lock duration in seconds
    /// @return creationTimestamp The source block timestamp at creation
    /// @return maturityTimestamp The maturity timestamp
    function extractFacts(
        bytes calldata lockEventProof
    ) external view returns (
        bytes32 lockId,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 principalAmount,
        uint256 durationSecs,
        uint256 creationTimestamp,
        uint256 maturityTimestamp,
        address baseRecipient,
        uint8 outputToken
    );

    /// @notice Canonical asset id of the asset the proven lock actually holds
    /// (keccak256(abi.encodePacked(environmentId, assetId)) as in the registry).
    /// Reverts when the lock cannot be proven or its asset cannot be established
    /// from proven data. The Verifier requires it to equal the package's
    /// canonicalAssetId (VF-XCH-011: asset mismatch).
    function extractAssetId(bytes calldata lockEventProof) external view returns (bytes32 canonicalAssetId);
}

// VF-FEE-009 (fix 2026-10-23, AG-09): the reader reports the Dev Fund that
// the proven lock actually paid its fee to. The Verifier requires it to equal
// the Dev Fund configured for that environment. A reader that cannot prove it
// is refused (fail closed).
interface ILockDevFundSource {
    function lockDevFund(string calldata environmentId, bytes calldata lockEventProof) external view returns (address);
}

// ---------------------------------------------------------------------------
// ERC-20 interface for VCLM and CHONX token contracts (BASE-TOK)
// ---------------------------------------------------------------------------

interface IERC20 {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function minterStake() external view returns (address);
}

// Treasury Reward Stake views read by the Verifier (t262u). The Stake contract
// is VCLM's stake minter, fixed by VCLM.initialize before finalize.
interface IStakeRewardView {
    function cumulativeRewardVclmMinted() external view returns (uint256);
    function synthToken() external view returns (address);
}

// ---------------------------------------------------------------------------
// Immutable asset-precision entry (BASE-QNORM)
// ---------------------------------------------------------------------------

struct AssetPrecisionEntry {
    bytes32 canonicalAssetId;    // keccak256(environmentId, assetId)
    string symbol;
    uint8 decimals;
    uint8 custodyClass;          // 1=S1, 2=S2, 3=S3
    uint8 custodyPath;           // 0=native, 1=token
}

// ---------------------------------------------------------------------------
// Canonical ProofPackage (Section D — normalized cross-chain evidence)
// This is the single structure every source environment normalizes into.
// ---------------------------------------------------------------------------

struct ProofPackage {
    // Source identity
    string sourceEnvironmentId;       // e.g. "Solana", "XRPL", "Bitcoin"
    bytes32 commitmentVaultLockId;    // unique per environment

    // Handshake
    uint8 handshakeAllowanceCount;   // ignored: Rev 12 removed the Handshake allowance (kept for ABI compatibility)

    // Asset identity + quantity
    bytes32 canonicalAssetId;         // keccak256 of canonical asset identity
    uint8 assetPrecision;             // decimals (from immutable table, NOT relayer)
    uint8 assetCustodyClass;          // 1=S1, 2=S2, 3=S3
    uint256 grossAmountSmallestUnits;
    uint256 actualFeeAmountSmallestUnits;
    uint256 principalAmountSmallestUnits;
    bytes32 feeAssetId;               // = canonicalAssetId (original-form routing)

    // Fee routing evidence
    string devFundDestination;
    bytes32 feeTransferEvidence;      // canonical fee tx hash

    // Timing
    uint256 valuationTimestamp;        // source block timestamp
    uint256 maturityTimestamp;
    uint256 durationSecs;

    // Output
    uint8 selectedOutputToken;         // 0=VCLM, 1=CHONX

    // Bindings
    address baseRecipient;             // EVM address (nonzero)
    string releaseDestination;         // source-chain address

    // CHONX activation receipt. Kept only for ABI stability (the tuple and
    // the recordFeeAndRac / verifyAndMint selectors). Not read: VF-COM-025 is
    // enforced from the chain reader's lock creation time (t271u).
    bytes chonxActivationReceipt;

    // RAC identity. Kept only for ABI stability. Not read (fix 2026-10-23,
    // AG-04): the Verifier keys every RAC by racKey(environment, proven lock
    // id), so one proven lock earns exactly one RAC (VF-RAC-001 / VF-FEE-011).
    bytes32 racIdentity;

    // Price record (VF-ORC): optional encoding of the lock-creation reference
    // price. Every valuation reads the registry's last successful scheduled
    // price at first lock valuation and retains it (VF-ORC-008/009/010).
    // Ethereum USDC/USDT use the same scheduled prices as every other asset.
    bytes priceRecord;

    // Chain-specific proofs (opaque to normalizer, consumed by IChainVerifier)
    bytes sourceFinalityProof;
    bytes lockEventProof;
}

// ---------------------------------------------------------------------------
// VinculumFinalisVerifier — the recognition boundary
// ---------------------------------------------------------------------------

contract VinculumFinalisVerifier {

    // ===== Protocol constants (verbatim from Revision 6) =====

    uint256 public constant SCALE = 1e18;
    uint256 public constant TOKEN_DECIMALS = 18;

    // VF-TOK-009/010: hard caps
    uint256 public constant VCLM_HARD_CAP = 10_000_000_000 * 1e18;
    uint256 public constant CHONX_HARD_CAP = 100_000_000_000 * 1e18;

    // VF-TOK-002: CHONX activation threshold
    uint256 public constant CHONX_ACTIVATION_THRESHOLD = 10_000_000 * 1e18;

    // VF-COM-003/009: fee basis points
    uint256 public constant STANDARD_FEE_BPS = 500;    // 5.00%, every duration incl. Handshake
    uint256 public constant HANDSHAKE_DURATION_SECS = 3600;

    // VF-COM-003: handshake USD range
    uint256 public constant HANDSHAKE_USD_MIN = 0.01e18;
    uint256 public constant HANDSHAKE_USD_MAX = 0.02e18;
    uint256 public constant STANDARD_USD_MIN = 0.01e18;

    // VF-COM-003 (t238u): Bitcoin, Bitcoin Cash and Litecoin native Handshakes.
    // 5% of $0.02 is under dust on these three chains, so the USD band refused
    // every Handshake there. For these three only, the Handshake band is in
    // smallest units (inclusive): the minimum is 20 x the P2PKH dust limit
    // (546 / 546 / 5,460) rounded up, the maximum is twice the minimum. The USD
    // used for their Handshake issuance and RAC is capped at HANDSHAKE_USD_MAX,
    // so a larger Handshake does not mint more than a $0.02 Handshake.
    // Every other chain keeps the USD band above, unchanged.
    uint256 public constant BTC_HANDSHAKE_MIN_UNITS = 11_000;   // sats
    uint256 public constant BTC_HANDSHAKE_MAX_UNITS = 22_000;
    uint256 public constant BCH_HANDSHAKE_MIN_UNITS = 11_000;   // sats
    uint256 public constant BCH_HANDSHAKE_MAX_UNITS = 22_000;
    uint256 public constant LTC_HANDSHAKE_MIN_UNITS = 110_000;  // litoshis
    uint256 public constant LTC_HANDSHAKE_MAX_UNITS = 220_000;
    // Native asset ids exactly as the UTXO readers report them
    // (UtxoLockReader.nativeAssetId = keccak256(abi.encodePacked(env, nativeAsset)))
    // and as the registry rows carry them. _verifySource requires the proven
    // asset to equal pkg.canonicalAssetId.
    bytes32 public constant BTC_NATIVE_ASSET_ID = keccak256(abi.encodePacked("Bitcoin", "native-BTC"));
    bytes32 public constant BCH_NATIVE_ASSET_ID = keccak256(abi.encodePacked("Bitcoin Cash", "native-BCH"));
    bytes32 public constant LTC_NATIVE_ASSET_ID = keccak256(abi.encodePacked("Litecoin", "native-LTC"));

    // Verified USDC/USDT identities (see isUsdStableIdentity, matched by
    // environment and contract, never by symbol): a last successful scheduled
    // price below $0.95 makes the asset unavailable for every new valuation,
    // at every duration, until a later run is >= $0.95. Exactly $0.95 is
    // allowed. A lock already bound keeps its creation price.
    uint256 public constant USD_STABLE_MIN_PRICE = 0.95e30;

    // VF-ORC-016 (t448u price precision): every scheduled price is USD per
    // whole token with 30 decimals (priceUsd30), stored in a uint128. The
    // smallest representable price is 1e-30 USD per whole token, so a token
    // priced below 1e-18 USD (for example TigerOG near 7.4e-19) keeps its real
    // value instead of rounding to 0 or 1e-18. The largest storable price is
    // type(uint128).max / 1e30, about 340,282,366 USD per whole token; a
    // larger price is refused (fail closed). Valuation is
    //   usd18 = floor(gross * priceUsd30 / 10**(decimals + 12))
    // computed in full 512-bit precision with one floor rounding, so a
    // valuation is never rounded up and never overflows silently.
    uint256 public constant PRICE_SCALE = 1e30;
    uint256 public constant PRICE_TO_USD18_DIVISOR = 1e12;
    uint8 public constant MAX_VALUATION_DECIMALS = 65;

    // VF-COM-019: decay
    uint256 public constant DECAY_SURVIVAL_FP = 983330000000000000; // 0.98333
    uint256 public constant DECAY_PERIOD_DAYS = 30;

    // VF-RAC-003 / VF-STK-006: Epoch duration = 10 days (FIXED_RULES.epoch_days)
    uint256 public constant EPOCH_DURATION_SECS = 10 * 1 days;
    // VF-RAC-005: Permanent $0.10 Reward Reference Value (100 cents / 10 cents = 10x)
    uint256 public constant REWARD_REFERENCE_CENTS = 10;

    // Emission rates
    uint256 public constant VCLM_INITIAL_RATE = 10e18;     // 10 VCLM per $1.00
    uint256 public constant VCLM_FLOOR_RATE = 1e18;        // 1 VCLM per $1.00
    uint256 public constant CHONX_INITIAL_RATE = 100e18;    // 100 CHONX per $1.00
    uint256 public constant CHONX_FLOOR_RATE = 10e18;      // 10 CHONX per $1.00

    // Asset class multipliers (bps)
    uint16 public constant S1_MULTIPLIER_BPS = 15000; // 1.5x
    uint16 public constant S2_MULTIPLIER_BPS = 13000; // 1.3x
    uint16 public constant S3_MULTIPLIER_BPS = 10000; // 1.0x

    // Reward-accounting credit rate
    uint256 public constant RAC_CREDIT_RATE_BPS = 6000; // 60%

    // ===== Storage =====

    // CL-02 / VF-DEP-006: one-shot deployment right, destroyed by finalize().
    address public deployer;

    // VF-DEP-007: finalization independently verifiable on-chain.
    // Renamed from `finalized` to avoid shadowing the chain-finality local
    // at verifyAndMint(). Two unrelated meanings must not share a name in a
    // contract that cannot be patched after deployment (VF-IMM-006).
    bool public configurationFinalized;

    // VF-XCH-013: replay protection — keccak256(env, lockId) => consumed
    mapping(bytes32 => bool) public consumedLocks;

    // VF-RAC-001: RAC exact-once, keyed by racKey(environment, proven lock id)
    mapping(bytes32 => bool) public recordedRacs;

    // BASE-CAP: lifetime issuance
    uint256 public cumulativeVclmIssued;
    uint256 public cumulativeChonxIssued;

    // BASE-ACT: CHONX activation
    bool public chonxActivated;
    uint256 public chonxActivationBlock;
    // t271u VF-COM-025: Base block timestamp of activation. A CHONX lock mints
    // only if its creation time (from the chain reader) is after it: Base
    // locks strictly later (Base block timestamps strictly increase, so an
    // equal time is the same block and is refused), other chains at least
    // CHONX_SOURCE_CLOCK_MARGIN_SECS later (their clocks are not Base's).
    uint256 public chonxActivationTimestamp;
    uint256 public constant CHONX_SOURCE_CLOCK_MARGIN_SECS = 1 days;

    // BASE-RAC: RAC credits (indexed by racKey(environment, proven lock id))
    mapping(bytes32 => uint256) public racCredits;
    mapping(bytes32 => uint256) public racEpoch;

    // VF-RAC-003/004 (t262u): Epoch Reward Basis per epoch, the sum of the
    // credits recorded in it. Epoch N (1-indexed) is
    // [T0 + (N-1) x 10 days, T0 + N x 10 days), T0 = protocolLaunchTimestamp
    // (Section 10.2). The Stake contract reads this at epoch close.
    mapping(uint256 => uint256) public epochRewardBasis;

    // BASE-QNORM: immutable asset-precision table
    // keccak256(environmentId, canonicalAssetId) => AssetPrecisionEntry
    mapping(bytes32 => AssetPrecisionEntry) public assetPrecisionTable;

    // VF-ORC scheduled prices (PRICE-DELIVER). Not a deployment-time price hash.
    // keccak256(environmentId, canonicalAssetId) => last scheduled-run result.
    // usable=false means no new Commitment Vault valuation until a later success.
    struct ScheduledPriceEntry {
        uint256 priceUsd30;
        bool usable;
    }
    mapping(bytes32 => ScheduledPriceEntry) public scheduledPrices;

    // VF-ORC-008/009/010 (fix 2026-10-23, AG-06): every scheduled-run result
    // per asset key, in posting order, with the Base block timestamp of the
    // run. The price for a lock is the record in effect when the lock was
    // created: the last record posted strictly before the proven creation
    // time. priceUsd30 == 0 marks a failed run (asset unavailable). Records
    // are append-only and postedAt never decreases, so the price for a lock
    // does not depend on when or by whom the lock is submitted.
    struct PricePoint {
        uint128 priceUsd30;
        uint64 postedAt;
        uint64 runId;
    }
    mapping(bytes32 => PricePoint[]) private _priceHistory;

    // VF-ORC-009/010: lock-creation reference price retained per lock.
    // keccak256(env, lockId) => bound price (bound=true after first valuation).
    struct LockPriceBinding {
        uint256 priceUsd30;
        bool bound;
    }
    mapping(bytes32 => LockPriceBinding) public lockReferencePrices;

    // Only this address may write scheduled-run results (not an invent-price admin).
    address public scheduledPricePoster;

    // Registry row 2 (native ETH) canonical asset id, also registered under
    // "Base". finalize() requires this Base row and its usable price.
    bytes32 public constant BASE_NATIVE_ETH_ASSET_ID =
        0xde7085290190e1f2f7f2f83d26fa72e411f9d765ddd608a77e8a7c388113943b;
    uint64 public lastScheduledRunId;

    // VF-ORC-011/013: emission rate uses Valuation Timestamp vs protocol launch.
    uint256 public protocolLaunchTimestamp;

    // Per-environment verifier registry (Section O)
    // environmentId => IChainVerifier
    mapping(string => IChainVerifier) public chainVerifiers;

    // Dev Fund destinations (VF-FEE-004) — PENDING_DEPLOYMENT until provisioned
    // environmentId => devFundAddress
    mapping(string => address) public devFundDestinations;

    // Token contracts (BASE-TOK)
    IERC20 public vclmToken;
    IERC20 public chonxToken;

    // ===== Events =====

    event VerificationSucceeded(
        bytes32 indexed lockIdHash,
        string sourceEnvironmentId,
        address indexed recipient,
        uint8 outputToken,
        uint256 amount
    );

    event VerificationRejected(
        bytes32 indexed lockIdHash,
        string sourceEnvironmentId,
        string reason
    );

    event RacCreditRecorded(
        bytes32 indexed racKey,
        uint256 creditAmount,
        uint256 epoch
    );

    event ChonxActivated(uint256 activationBlock);

    event DevFundConfigured(string environmentId, address devFundDestination);
    event ChainVerifierRegistered(string environmentId, address verifier);
    event DeploymentFinalized();
    event ScheduledPricePosterSet(address poster);
    event ScheduledPriceRunApplied(uint64 indexed runId, uint256 updateCount);
    event ScheduledPriceUpdated(
        bytes32 indexed assetKey,
        string environmentId,
        bytes32 canonicalAssetId,
        uint256 priceUsd30,
        bool usable,
        uint64 runId
    );

    // ===== Modifiers =====

    // CL-02 / VF-DEP-001/006: configuration is open ONLY during the deployment
    // ceremony, and only to the deployer. finalize() destroys that right.
    modifier onlyDuringDeployment() {
        require(!configurationFinalized, "VF-DEP-003: configuration finalized");
        require(msg.sender == deployer, "VF: not deployer");
        _;
    }

    // VF-DEP-001: the implementation remains INACTIVE until configuration is
    // populated and validated.
    modifier onlyWhenFinalized() {
        require(configurationFinalized, "VF-DEP-001: not finalized");
        _;
    }

    // ===== Constructor =====

    constructor(address _vclmToken, address _chonxToken) {
        deployer = msg.sender;
        vclmToken = IERC20(_vclmToken);
        chonxToken = IERC20(_chonxToken);
    }

    // ===== Configuration — deployment ceremony only (VF-DEP-001/006) =====
    //
    // These remain open across many transactions because the asset registry
    // requires ~1,001 entries; VF-DEP-001 contemplates exactly this by holding
    // the implementation inactive until population is complete. finalize()
    // closes the window irreversibly.

    function registerAssetPrecision(
        string calldata environmentId,
        bytes32 canonicalAssetId,
        string calldata symbol,
        uint8 decimals,
        uint8 custodyClass,
        uint8 custodyPath
    ) external onlyDuringDeployment {
        bytes32 key = keccak256(abi.encodePacked(environmentId, canonicalAssetId));
        assetPrecisionTable[key] = AssetPrecisionEntry({
            canonicalAssetId: canonicalAssetId,
            symbol: symbol,
            decimals: decimals,
            custodyClass: custodyClass,
            custodyPath: custodyPath
        });
    }

    struct AssetPrecisionInput {
        string environmentId;
        bytes32 canonicalAssetId;
        string symbol;
        uint8 decimals;
        uint8 custodyClass;
        uint8 custodyPath;
    }

    /// @notice Registers several asset precision entries in one call. Each item is
    ///         written exactly as registerAssetPrecision writes it.
    /// @dev Deployment ceremony only (same onlyDuringDeployment rule). At most 50
    ///         items per call.
    function registerAssetPrecisionBatch(AssetPrecisionInput[] calldata items) external onlyDuringDeployment {
        require(items.length <= 50, "VF-REG: batch exceeds 50");
        for (uint256 i = 0; i < items.length; i++) {
            AssetPrecisionInput calldata it = items[i];
            bytes32 key = keccak256(abi.encodePacked(it.environmentId, it.canonicalAssetId));
            assetPrecisionTable[key] = AssetPrecisionEntry({
                canonicalAssetId: it.canonicalAssetId,
                symbol: it.symbol,
                decimals: it.decimals,
                custodyClass: it.custodyClass,
                custodyPath: it.custodyPath
            });
        }
    }

    // ===== Token address index (environment + token address -> registry row) =====
    //
    // Registry rows are keyed by canonicalAssetId = keccak256(env, label); a
    // lock records only the token ADDRESS. This index is the missing link: it
    // maps keccak256(abi.encode(environmentId, tokenAddress)) - the key a reader
    // reports for a proven token lock - to the row's canonicalAssetId, using the
    // address already on each registry row. Written in the ceremony only; one
    // row per (environment, address); the row must already be registered in
    // that same environment.
    mapping(bytes32 => bytes32) public tokenAssetIndex;

    struct TokenAddressInput {
        string environmentId;
        address token;
        bytes32 canonicalAssetId;
    }

    // ===== Registry row alias (an environment's asset priced by another environment's row) =====
    //
    // keccak256(env, canonicalAssetId) -> the registry key of the row it uses.
    // Polygon native POL has no Polygon row; it uses the existing POL row
    // (environment Ethereum, the POL token) for precision and price, so the
    // registry stays 961 rows plus Base ETH. Ceremony only.
    mapping(bytes32 => bytes32) public assetRowAlias;

    function _assetKey(string memory environmentId, bytes32 canonicalAssetId) internal view returns (bytes32) {
        bytes32 k = keccak256(abi.encodePacked(environmentId, canonicalAssetId));
        bytes32 a = assetRowAlias[k];
        return a != bytes32(0) ? a : k;
    }

    function registerAssetRowAlias(
        string calldata environmentId,
        bytes32 canonicalAssetId,
        string calldata rowEnvironmentId
    ) external onlyDuringDeployment {
        bytes32 k = keccak256(abi.encodePacked(environmentId, canonicalAssetId));
        bytes32 rowKey = keccak256(abi.encodePacked(rowEnvironmentId, canonicalAssetId));
        require(assetPrecisionTable[rowKey].canonicalAssetId != bytes32(0), "VF-REG: alias row not registered");
        require(assetPrecisionTable[k].canonicalAssetId == bytes32(0), "VF-REG: environment already has this row");
        require(assetRowAlias[k] == bytes32(0), "VF-REG: alias already set");
        assetRowAlias[k] = rowKey;
    }

    function _isProtocolToken(address token) internal view returns (bool) {
        if (token == address(vclmToken) || token == address(chonxToken)) return true;
        address stake = vclmToken.minterStake();
        return stake != address(0) && token == IStakeRewardView(stake).synthToken();
    }

    function tokenAddressKey(string memory environmentId, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(environmentId, token));
    }

    function registerTokenAddressBatch(TokenAddressInput[] calldata items) external onlyDuringDeployment {
        require(items.length <= 50, "VF-REG: batch exceeds 50");
        for (uint256 i = 0; i < items.length; i++) {
            TokenAddressInput calldata it = items[i];
            require(it.token != address(0), "VF-REG: zero token address");
            // VF-TOK-007 / VF-REG-008: protocol tokens are never lock inputs,
            // so their addresses can never be indexed to a registry row.
            require(!_isProtocolToken(it.token), "VF-REG-008: protocol token is not a lock input");
            require(
                assetPrecisionTable[keccak256(abi.encodePacked(it.environmentId, it.canonicalAssetId))].canonicalAssetId != bytes32(0),
                "VF-REG: row not registered in this environment"
            );
            bytes32 k = tokenAddressKey(it.environmentId, it.token);
            require(tokenAssetIndex[k] == bytes32(0), "VF-REG: address already indexed");
            tokenAssetIndex[k] = it.canonicalAssetId;
            // $0.95 cutoff scope: the row this exact (environment, contract)
            // identity is indexed to. The row's symbol plays no part.
            if (isUsdStableIdentity(it.environmentId, it.token)) {
                usdStableRow[keccak256(abi.encodePacked(it.environmentId, it.canonicalAssetId))] = true;
            }
        }
    }

    // ===== $0.95 stablecoin cutoff scope (D-56, D-68; t430u item 4) =====
    //
    // Registry row key keccak256(abi.encodePacked(env, canonicalAssetId)) ->
    // true when a verified USDC/USDT identity is indexed to that row. Written
    // only by registerTokenAddressBatch, so only in the ceremony.
    mapping(bytes32 => bool) public usdStableRow;

    /// @notice The verified USDC and USDT identities that take the $0.95
    ///         new-lock cutoff (design D.4, STABLECOIN_IDENTITIES_2026-10-25.json):
    ///         exact environment and contract, never a ticker. A token that only
    ///         calls itself USDC or USDT is not on this list. Avalanche USDT.e is
    ///         not on the list (D-74).
    function isUsdStableIdentity(string memory environmentId, address token) public pure returns (bool) {
        bytes32 e = keccak256(bytes(environmentId));
        if (e == keccak256("Base")) {
            return token == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 // USDC (Circle)
                || token == 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2; // USDT (bridged, OP standard)
        }
        if (e == keccak256("Ethereum")) {
            return token == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 // USDC
                || token == 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
        }
        if (e == keccak256("Arbitrum")) {
            return token == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 // USDC
                || token == 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8 // USDC.e (bridged)
                || token == 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT0
        }
        if (e == keccak256("Optimism")) {
            return token == 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85 // USDC
                || token == 0x7F5c764cBc14f9669B88837ca1490cCa17c31607 // USDC.e (bridged)
                || token == 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58 // USDT (bridged)
                || token == 0x01bFF41798a0BcF287b996046Ca68b395DbC1071; // USDT0
        }
        if (e == keccak256("Polygon")) {
            return token == 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 // USDC
                || token == 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174 // USDC.e (bridged)
                || token == 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // USDT0
        }
        if (e == keccak256("BNB Smart Chain")) {
            return token == 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d // USDC (Binance-Peg)
                || token == 0x55d398326f99059fF775485246999027B3197955; // USDT (Binance-Peg)
        }
        if (e == keccak256("Avalanche")) {
            return token == 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E // USDC
                || token == 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7; // USDT
        }
        return false;
    }

    /// @notice Sets the address authorized to write scheduled price runs (VF-ORC-007).
    /// @dev Deployment ceremony only. Poster writes batched run results; it is not
    ///      an admin setter that invents ad-hoc prices outside a scheduled run.
    function setScheduledPricePoster(address poster) external onlyDuringDeployment {
        require(poster != address(0), "VF-ORC-007: zero price poster");
        scheduledPricePoster = poster;
        emit ScheduledPricePosterSet(poster);
    }

    function registerChainVerifier(string calldata environmentId, address verifier) external onlyDuringDeployment {
        // VF-DEP-002: zero or provisional configuration cannot be finalized.
        require(verifier != address(0), "VF-DEP-002: zero chain verifier");
        chainVerifiers[environmentId] = IChainVerifier(verifier);
        emit ChainVerifierRegistered(environmentId, verifier);
    }

    function configureDevFund(string calldata environmentId, address devFundDestination) external onlyDuringDeployment {
        require(devFundDestination != address(0), "VF: zero dev fund");
        devFundDestinations[environmentId] = devFundDestination;
        emit DevFundConfigured(environmentId, devFundDestination);
    }

    /// @notice Closes the deployment ceremony permanently (VF-DEP-006).
    /// @dev Irreversible. No setter re-opens it. After this call there is no
    ///      address on earth that can alter registry, chain verifiers, or Dev
    ///      Fund destinations (VF-IMM-001/002/004, VF-DEP-003).
    function finalize() external onlyDuringDeployment {
        require(address(chainVerifiers["Base"]) != address(0), "VF-DEP-010: Base reader not registered");
        bytes32 baseEthKey = keccak256(abi.encodePacked("Base", BASE_NATIVE_ETH_ASSET_ID));
        require(assetPrecisionTable[baseEthKey].canonicalAssetId != bytes32(0), "VF-DEP-011: Base ETH registry row missing");
        require(devFundDestinations["Base"] != address(0), "VF-DEP-012: Base Dev Fund not set");
        require(scheduledPricePoster != address(0), "VF-DEP-013: price poster not set");
        ScheduledPriceEntry memory sp = scheduledPrices[baseEthKey];
        require(sp.usable && sp.priceUsd30 > 0, "VF-DEP-014: Base ETH price not usable");
        configurationFinalized = true;
        if (protocolLaunchTimestamp == 0) {
            protocolLaunchTimestamp = block.timestamp;
        }
        deployer = address(0);
        emit DeploymentFinalized();
    }

    // ===== Scheduled price delivery (VF-ORC-001/004/005/007/008) =====
    //
    // Off-chain PRICE-FETCH runs twice per day (VF-ORC-001) with first-valid
    // cascade (VF-ORC-002/003/006). This function is the sole on-chain write
    // path for prices. A failed asset in a run is marked unusable
    // (fail closed); prior successful prices are not kept usable (VF-ORC-008).

    struct ScheduledPriceUpdate {
        string environmentId;
        bytes32 canonicalAssetId;
        uint256 priceUsd30;
        bool success;
    }

    function applyScheduledPriceRun(
        uint64 runId,
        ScheduledPriceUpdate[] calldata updates
    ) external {
        require(msg.sender == scheduledPricePoster, "VF-ORC-007: not price poster");
        // The poster may write before finalize (finalize requires a usable
        // Base ETH price) and after it. A failed asset is kept unusable.
        // Fix 2026-10-23 (AG-07): run ids are sequential. A jump (for example
        // to 2^64-1, which froze every later run) is refused.
        require(runId == lastScheduledRunId + 1, "VF-ORC-001: run id must be the next in sequence");
        lastScheduledRunId = runId;

        for (uint256 i = 0; i < updates.length; i++) {
            ScheduledPriceUpdate calldata u = updates[i];
            bytes32 key = keccak256(abi.encodePacked(u.environmentId, u.canonicalAssetId));
            AssetPrecisionEntry memory entry = assetPrecisionTable[key];
            require(entry.canonicalAssetId != bytes32(0), "VF-REG-001: asset not in registry");
            if (u.success) {
                require(u.priceUsd30 > 0, "VF-ORC-004: zero price");
                require(u.priceUsd30 <= type(uint128).max, "VF-ORC-004: price out of range");
                scheduledPrices[key] = ScheduledPriceEntry({
                    priceUsd30: u.priceUsd30,
                    usable: true
                });
                _priceHistory[key].push(PricePoint({
                    priceUsd30: uint128(u.priceUsd30),
                    postedAt: uint64(block.timestamp),
                    runId: runId
                }));
                emit ScheduledPriceUpdated(key, u.environmentId, u.canonicalAssetId, u.priceUsd30, true, runId);
            } else {
                // VF-ORC-005/008: no usable valuation until a later successful run.
                scheduledPrices[key] = ScheduledPriceEntry({
                    priceUsd30: 0,
                    usable: false
                });
                _priceHistory[key].push(PricePoint({
                    priceUsd30: 0,
                    postedAt: uint64(block.timestamp),
                    runId: runId
                }));
                emit ScheduledPriceUpdated(key, u.environmentId, u.canonicalAssetId, 0, false, runId);
            }
        }
        emit ScheduledPriceRunApplied(runId, updates.length);
    }

    // ===== Two-phase verification: RAC recording independent of issuance =====
    //
    // VF-FEE-011: "Completed fee non-refundable even if issuance impossible; verified fee
    //   still creates RAC (unless VCLM cap zero)."
    // VF-RAC-002: "RAC = 60% of Verified USD Fee Value on fee verification."
    // VF-SUP-012: "At zero VCLM capacity, fees still reach Dev Fund for valid CHONX output
    //   but no RAC (fee verification proceeds)."
    //
    // In a single EVM transaction, a later require() failure reverts all state changes.
    // To ensure RAC persists even if issuance is impossible (hard cap exceeded, finality
    // not yet achieved, etc.), the fee verification + RAC recording is a separate
    // external function that can be called independently before verifyAndMint().

    /// @notice Phase 1: Verifies fee math and records the Reward-Accounting Credit.
    /// @dev Can be called independently of verifyAndMint(). Persists RAC even if
    ///      issuance later fails (VF-FEE-011). Idempotent — reverts if RAC already recorded.
    function recordFeeAndRac(
        ProofPackage calldata pkg
    ) external onlyWhenFinalized {
        // The lock must exist: the source is proven, and the package checked
        // against it (including its asset), before any fee or RAC is recorded.
        uint256 createdAt = _verifySource(pkg);

        // VF-RAC-001 / VF-FEE-011: RAC exact-once per proven lock. The key is
        // derived from the environment and the proven lock id; the package's
        // racIdentity is not trusted (fix 2026-10-23, AG-04).
        bytes32 rk = racKey(pkg.sourceEnvironmentId, pkg.commitmentVaultLockId);
        require(!recordedRacs[rk], "VF-RAC-001: RAC already recorded");

        // VF-REG-001: Asset must be in registry (validates asset identity)
        bytes32 assetKey = _assetKey(pkg.sourceEnvironmentId, pkg.canonicalAssetId);
        AssetPrecisionEntry memory entry = assetPrecisionTable[assetKey];
        require(entry.canonicalAssetId != bytes32(0), "VF-REG-001: asset not in registry");

        // Rev 12 (fix 2026-10-23, AG-20): the Handshake has no allowance, so
        // pkg.handshakeAllowanceCount is ignored and nothing is counted.

        // VF-COM-011/012/013: Fee math verification
        uint256 gross = pkg.grossAmountSmallestUnits;
        uint256 fee = pkg.actualFeeAmountSmallestUnits;
        uint256 principal = pkg.principalAmountSmallestUnits;
        require(fee <= gross && gross - fee == principal, "VF-COM-012: principal != gross - fee");
        require(fee > 0 && principal > 0, "VF-COM-013: zero fee or principal");

        bool isHandshake = pkg.durationSecs == HANDSHAKE_DURATION_SECS;
        _requireGrossInRange(gross);
        require(fee == (gross * STANDARD_FEE_BPS) / 10000, "VF-COM-011: fee != floor(gross * bps / 10000)");

        // VF-COM-001/002: Duration must be permitted
        require(_isPermittedDuration(pkg.durationSecs), "VF-COM-002: duration not permitted");

        // CL-01: derive USD; never trust a caller-supplied verifiedGrossUsdMicro
        uint256 verifiedGrossUsdMicro = _resolveVerifiedGrossUsd(pkg, entry, createdAt);

        // VF-COM-003/009: value bounds. Returns the USD used for RAC: equal to
        // verifiedGrossUsdMicro except for a BTC/BCH/LTC native Handshake, where
        // it is capped at HANDSHAKE_USD_MAX.
        uint256 creditUsd = _checkValueBounds(pkg, isHandshake, verifiedGrossUsdMicro);

        // VF-FEE-011 / VF-RAC-002: Record RAC on fee verification, independent of issuance.
        // VF-RAC-008: No RAC after VCLM capacity = 0 (fee verification still proceeds).
        // VF-SUP-012: At zero VCLM capacity, fees still reach Dev Fund but no RAC.
        recordedRacs[rk] = true;
        if (lifetimeVclmIssued() < VCLM_HARD_CAP) {
            uint256 feeUsd = (creditUsd * fee) / gross;
            uint256 racCredit = (feeUsd * RAC_CREDIT_RATE_BPS) / 10000;
            // VF-RAC-003 / VF-STK-007: the epoch in which the credit is recorded
            // on Base, on the Section 10.2 launch-based epochs.
            uint256 epoch = currentEpoch();
            racCredits[rk] = racCredit;
            racEpoch[rk] = epoch;
            epochRewardBasis[epoch] += racCredit; // VF-RAC-004
            emit RacCreditRecorded(rk, racCredit, epoch);
        }
    }

    // ===== Source verification (VF-XCH-006/010/011) =====

    /// @dev Proves the source lock through the registered chain reader and
    ///      cross-checks the package against the facts the reader extracts.
    ///      Called by recordFeeAndRac (before any write, so no fee or RAC is
    ///      recorded for a lock that does not exist) and by verifyAndMint.
    ///      The asset the lock actually holds must equal the package asset.
    function _verifySource(ProofPackage calldata pkg) internal view returns (uint256 extCreated) {
        IChainVerifier verifier = chainVerifiers[pkg.sourceEnvironmentId];
        require(address(verifier) != address(0), "VF-XCH-006: no verifier registered for environment");
        (bool finalized, bytes32 sourceBlockHash, uint256 sourceBlockHeight) =
            verifier.verifyFinality(pkg.lockEventProof, pkg.sourceFinalityProof);
        require(finalized, "VF-XCH-006: source not finalized");
        // An empty block hash or height 0 is never finalized (VF-XCH-034).
        require(sourceBlockHash != bytes32(0) && sourceBlockHeight != 0, "VF-XCH-006: empty finalized block");

        // VF-XCH-011: Independently extract immutable facts from the raw lock event
        // proof and cross-check against the normalized ProofPackage fields. This
        // prevents tampering by the normalizer/relayer — the chain verifier
        // extracts directly from the chain-specific event, not from normalized fields.
        (
            bytes32 extLockId,
            uint256 extGross,
            uint256 extFee,
            uint256 extPrincipal,
            uint256 extDuration,
            uint256 extCreation,
            ,
            address extRecipient,
            uint8 extOutputToken
        ) = verifier.extractFacts(pkg.lockEventProof);
        require(
            keccak256(abi.encodePacked(extLockId)) == keccak256(abi.encodePacked(pkg.commitmentVaultLockId)),
            "VF-XCH-011: lockId mismatch"
        );
        require(extGross == pkg.grossAmountSmallestUnits, "VF-XCH-011: gross mismatch");
        require(extFee == pkg.actualFeeAmountSmallestUnits, "VF-XCH-011: fee mismatch");
        require(extPrincipal == pkg.principalAmountSmallestUnits, "VF-XCH-011: principal mismatch");
        require(extDuration == pkg.durationSecs, "VF-XCH-011: duration mismatch");
        require(extRecipient == pkg.baseRecipient, "VF-XCH-011: recipient mismatch");
        require(extOutputToken == pkg.selectedOutputToken, "VF-XCH-011: output token mismatch");
        extCreated = extCreation;
        // VF-ORC-011 (fix 2026-10-23, AG-05): the Valuation Timestamp is the
        // proven lock creation time. A package that states another time is
        // refused; the proven time is what the Verifier uses.
        require(extCreation != 0, "VF-ORC-011: no proven lock creation time");
        require(extCreation <= block.timestamp, "VF-ORC-011: lock creation time in the future");
        require(pkg.valuationTimestamp == extCreation, "VF-ORC-011: valuation timestamp != proven lock creation time");
        // Native locks: the reader reports the native canonical id. Token locks:
        // the reader reports tokenAddressKey(env, token), resolved here through
        // the ceremony-written index to the registry row for that address.
        bytes32 provenAsset = verifier.extractAssetId(pkg.lockEventProof);
        require(
            pkg.canonicalAssetId != bytes32(0) &&
                (provenAsset == pkg.canonicalAssetId || tokenAssetIndex[provenAsset] == pkg.canonicalAssetId),
            "VF-XCH-011: asset mismatch"
        );

        // VF-FEE-009 (fix 2026-10-23, AG-09): a Dev Fund must be configured for
        // the environment, and the proven lock must have paid its fee to it.
        address configuredDevFund = devFundDestinations[pkg.sourceEnvironmentId];
        require(configuredDevFund != address(0), "VF-FEE-009: Dev Fund not configured for environment");
        address lockDevFund;
        try ILockDevFundSource(address(verifier)).lockDevFund(pkg.sourceEnvironmentId, pkg.lockEventProof) returns (address d) {
            lockDevFund = d;
        } catch {
            revert("VF-FEE-009: reader cannot prove the lock Dev Fund");
        }
        require(lockDevFund == configuredDevFund, "VF-FEE-009: lock Dev Fund != configured Dev Fund");
    }

    /// @notice RAC key for a proven lock (VF-RAC-001 / VF-FEE-011).
    function racKey(string memory environmentId, bytes32 lockId) public pure returns (bytes32) {
        return keccak256(abi.encode("VF-RAC", environmentId, lockId));
    }

    /// @dev FZ-04 (fix 2026-10-23): gross amounts that would overflow the fee
    ///      or valuation arithmetic are refused with a coded error, not a panic.
    function _requireGrossInRange(uint256 gross) internal pure {
        require(gross <= type(uint256).max / SCALE, "VF-COM-011: gross out of range");
    }

    // ===== Canonical verification entry point =====

    /// @notice Phase 2: Verifies a normalized proof package and mints tokens if valid.
    /// @dev Call recordFeeAndRac() first to persist RAC independently of issuance outcome.
    /// @param pkg The normalized ProofPackage from any source environment.
    /// @param daysSinceLaunch Kept for ABI stability. Not read: emission uses the
    ///        proven lock creation time (VF-ORC-011/013).
    /// @return success Whether verification succeeded and tokens were minted.
    function verifyAndMint(
        ProofPackage calldata pkg,
        uint256 daysSinceLaunch
    ) external onlyWhenFinalized returns (bool success) {
        bytes32 lockIdHash = keccak256(abi.encodePacked(pkg.sourceEnvironmentId, pkg.commitmentVaultLockId));

        // Step 1: Replay protection (VF-XCH-013)
        require(!consumedLocks[lockIdHash], "VF-XCH-013: replay");

        // Step 2: RAC must already be recorded (VF-FEE-011 two-phase pattern).
        // If not yet recorded, the caller must call recordFeeAndRac() first.
        require(
            recordedRacs[racKey(pkg.sourceEnvironmentId, pkg.commitmentVaultLockId)],
            "VF-FEE-011: call recordFeeAndRac() first"
        );

        // Step 3: Asset registry + precision (VF-REG-001, VF-QNORM)
        bytes32 assetKey = _assetKey(pkg.sourceEnvironmentId, pkg.canonicalAssetId);
        AssetPrecisionEntry memory entry = assetPrecisionTable[assetKey];
        require(entry.canonicalAssetId != bytes32(0), "VF-REG-001: asset not in registry");
        require(entry.decimals == pkg.assetPrecision, "VF-QNORM: precision mismatch");

        // Step 4: Fee math (VF-COM-011/012/013) — re-verified for safety
        uint256 gross = pkg.grossAmountSmallestUnits;
        uint256 fee = pkg.actualFeeAmountSmallestUnits;
        uint256 principal = pkg.principalAmountSmallestUnits;
        require(fee <= gross && gross - fee == principal, "VF-COM-012: principal != gross - fee");
        require(fee > 0 && principal > 0, "VF-COM-013: zero fee or principal");

        bool isHandshake = pkg.durationSecs == HANDSHAKE_DURATION_SECS;
        _requireGrossInRange(gross);
        require(fee == (gross * STANDARD_FEE_BPS) / 10000, "VF-COM-011: fee != floor(gross * bps / 10000)");

        // Step 11 (moved first, fix 2026-10-23): source finality, fact
        // cross-check and Dev Fund (VF-XCH-006/010/011, VF-FEE-009). The proven
        // creation time drives valuation and emission below.
        uint256 createdAt = _verifySource(pkg);

        // Step 5: Duration (VF-COM-001/002)
        require(_isPermittedDuration(pkg.durationSecs), "VF-COM-002: duration not permitted");

        // Step 6: USD value — derived, never caller-supplied (CL-01)
        uint256 verifiedGrossUsdMicro = _resolveVerifiedGrossUsd(pkg, entry, createdAt);
        // VF-COM-003/009: value bounds. issuanceUsd equals verifiedGrossUsdMicro
        // except for a BTC/BCH/LTC native Handshake, capped at HANDSHAKE_USD_MAX.
        uint256 issuanceUsd = _checkValueBounds(pkg, isHandshake, verifiedGrossUsdMicro);

        // Step 7: Output eligibility (VF-COM-020/025, VF-TOK-002)
        require(pkg.selectedOutputToken <= 1, "VF-COM-020: invalid output token");
        if (pkg.selectedOutputToken == 1) { // CHONX
            _syncChonxActivation(); // VF-TOK-002: stake reward VCLM may have crossed the threshold
            require(chonxActivated, "VF-COM-025: CHONX not activated");
        }

        // Step 8: removed by Rev 12 (fix 2026-10-23, AG-20). The Handshake has
        // no allowance limit and no identity counter; handshakeAllowanceCount
        // is ignored.

        // Step 9: Base recipient (VF-ARC-006)
        require(pkg.baseRecipient != address(0), "VF-ARC-006: zero base recipient");

        // Step 10: Dev Fund destination (VF-FEE-009): enforced in _verifySource
        // above (configured, nonzero, and equal to the proven lock's Dev Fund).

        // Step 11b (t271u): VF-COM-025 causal order from trusted data. CHONX
        // must already be active when the lock is created; a later activation
        // never cures an earlier lock. createdAt is the reader's creation time
        // (Base: the lock record's block.timestamp; other chains: the proven
        // source block or ledger time). Fixed once set, so a refused lock is
        // refused forever.
        if (pkg.selectedOutputToken == 1) {
            uint256 eligibleAfter = chonxActivationTimestamp;
            if (keccak256(bytes(pkg.sourceEnvironmentId)) != keccak256("Base")) {
                eligibleAfter += CHONX_SOURCE_CLOCK_MARGIN_SECS - 1;
            }
            require(createdAt > eligibleAfter, "VF-COM-025: lock created before CHONX activation");
        }

        // Step 12: Issuance calculation (VF-COM-018/019)
        // VF-ORC-011/013: emission rate from Valuation Timestamp, not caller-supplied age.
        uint256 emissionDays = _daysSinceLaunchFromValuation(createdAt);
        // daysSinceLaunch retained in the ABI for callers; valuation path is authoritative.
        daysSinceLaunch;
        uint256 issuanceAmount = _computeIssuance(
            issuanceUsd,
            pkg.selectedOutputToken,
            entry.custodyClass,
            pkg.durationSecs,
            emissionDays
        );

        // Step 13: Hard cap (VF-SUP-015)
        if (pkg.selectedOutputToken == 0) { // VCLM
            // VF-SUP-002: Commitment Vault and stake rewards share the VCLM cap.
            uint256 issued = lifetimeVclmIssued();
            uint256 remaining = issued >= VCLM_HARD_CAP ? 0 : VCLM_HARD_CAP - issued;
            require(issuanceAmount <= remaining, "VF-SUP-015: exceeds VCLM cap");
        } else { // CHONX
            uint256 remaining = CHONX_HARD_CAP - cumulativeChonxIssued;
            require(issuanceAmount <= remaining, "VF-SUP-015: exceeds CHONX cap");
        }

        // ===== All checks passed — authorize issuance =====
        // RAC already recorded at fee verification above.

        // Mint tokens (BASE-EMIT)
        if (pkg.selectedOutputToken == 0) { // VCLM
            cumulativeVclmIssued += issuanceAmount;
            vclmToken.mint(pkg.baseRecipient, issuanceAmount);

            // Check CHONX activation (BASE-ACT, VF-TOK-002)
            _syncChonxActivation();
        } else { // CHONX
            cumulativeChonxIssued += issuanceAmount;
            chonxToken.mint(pkg.baseRecipient, issuanceAmount);
        }

        // Consume replay lock (only on issuance success — VF-XCH-013)
        consumedLocks[lockIdHash] = true;

        emit VerificationSucceeded(lockIdHash, pkg.sourceEnvironmentId, pkg.baseRecipient, pkg.selectedOutputToken, issuanceAmount);
        return true;
    }

    // ===== Value bounds (VF-COM-003/009) =====

    /// @dev Smallest-unit Handshake band for the Bitcoin, Bitcoin Cash and
    ///      Litecoin native assets; (0, 0) for every other environment or asset.
    ///      Keyed on the proven native asset id and the environment together.
    function _utxoHandshakeUnits(ProofPackage calldata pkg) internal pure returns (uint256, uint256) {
        bytes32 a = pkg.canonicalAssetId;
        bytes32 e = keccak256(bytes(pkg.sourceEnvironmentId));
        if (a == BTC_NATIVE_ASSET_ID && e == keccak256("Bitcoin")) return (BTC_HANDSHAKE_MIN_UNITS, BTC_HANDSHAKE_MAX_UNITS);
        if (a == BCH_NATIVE_ASSET_ID && e == keccak256("Bitcoin Cash")) return (BCH_HANDSHAKE_MIN_UNITS, BCH_HANDSHAKE_MAX_UNITS);
        if (a == LTC_NATIVE_ASSET_ID && e == keccak256("Litecoin")) return (LTC_HANDSHAKE_MIN_UNITS, LTC_HANDSHAKE_MAX_UNITS);
        return (0, 0);
    }

    /// @dev Applies VF-COM-003/009 and returns the USD to use for RAC and
    ///      issuance. For every lock except a BTC/BCH/LTC native Handshake this
    ///      is the unchanged USD check and returns verifiedGrossUsd as is.
    function _checkValueBounds(
        ProofPackage calldata pkg,
        bool isHandshake,
        uint256 verifiedGrossUsd
    ) internal pure returns (uint256) {
        if (isHandshake) {
            (uint256 minUnits, uint256 maxUnits) = _utxoHandshakeUnits(pkg);
            if (minUnits != 0) {
                uint256 g = pkg.grossAmountSmallestUnits;
                require(g >= minUnits, "VF-COM-003: handshake gross below unit band");
                require(g <= maxUnits, "VF-COM-003: handshake gross above unit band");
                return verifiedGrossUsd > HANDSHAKE_USD_MAX ? HANDSHAKE_USD_MAX : verifiedGrossUsd;
            }
            require(
                verifiedGrossUsd >= HANDSHAKE_USD_MIN && verifiedGrossUsd <= HANDSHAKE_USD_MAX,
                "VF-COM-003: handshake USD outside $0.01-$0.02"
            );
        } else {
            require(verifiedGrossUsd >= STANDARD_USD_MIN, "VF-COM-009: standard USD below $0.01");
        }
        return verifiedGrossUsd;
    }

    // ===== USD resolution (VF-ORC / CL-01) =====
    // Every asset, including USDC/USDT: registry last successful scheduled
    // price, read and bound at first lock valuation (VF-ORC-008/009/010). No
    // deployment price hash. No admin invent-price setter. No $1 substitute.
    // The $0.95 cutoff applies to every new valuation of a verified USDC/USDT
    // identity, every duration.

    function _resolveVerifiedGrossUsd(
        ProofPackage calldata pkg,
        AssetPrecisionEntry memory entry,
        uint256 createdAt
    ) internal returns (uint256) {
        bytes32 lockIdHash = keccak256(
            abi.encodePacked(pkg.sourceEnvironmentId, pkg.commitmentVaultLockId)
        );
        LockPriceBinding storage binding = lockReferencePrices[lockIdHash];
        uint256 priceUsd30;

        if (binding.bound) {
            // VF-ORC-009/010: retain lock-creation reference; proof delay/retry does not reprice.
            priceUsd30 = binding.priceUsd30;
        } else {
            // Fix 2026-10-23 (AG-06, COMB-01/02/03): the record in effect at the
            // proven lock creation time, never the record current at
            // submission. No record, or a failed run in effect, refuses the
            // lock permanently (fail closed).
            bytes32 assetKey = _assetKey(pkg.sourceEnvironmentId, pkg.canonicalAssetId);
            priceUsd30 = _priceInEffectAt(assetKey, createdAt);
            require(priceUsd30 > 0, "VF-ORC-005: no usable scheduled price");
            // Verified USDC/USDT identity below $0.95 at lock creation:
            // unavailable. Fail closed; never substitute $1. The row is matched
            // by the exact (environment, contract) indexed to it, not by symbol.
            if (usdStableRow[keccak256(abi.encodePacked(pkg.sourceEnvironmentId, pkg.canonicalAssetId))]) {
                require(
                    priceUsd30 >= USD_STABLE_MIN_PRICE,
                    "VF-ORC-005: USDC/USDT scheduled price below $0.95"
                );
            }
            binding.priceUsd30 = priceUsd30;
            binding.bound = true;
        }

        // Optional package record must agree with the bound reference (VF-ORC-007/012).
        if (pkg.priceRecord.length > 0) {
            require(pkg.priceRecord.length == 32, "VF-ORC-007: price record length");
            uint256 recorded = abi.decode(pkg.priceRecord, (uint256));
            require(recorded == priceUsd30, "VF-ORC-007: price record mismatch");
        }

        // VF-ORC-016: one floor rounding in full precision. 10**(decimals+12)
        // fits in uint256 only up to decimals 65; larger is refused.
        require(entry.decimals <= MAX_VALUATION_DECIMALS, "VF-ORC-004: decimals out of range");
        uint256 denominator = (10 ** uint256(entry.decimals)) * PRICE_TO_USD18_DIVISOR;
        return _mulDivFloor(pkg.grossAmountSmallestUnits, priceUsd30, denominator);
    }

    /// @dev floor(a * b / d) with a 512-bit intermediate product. Reverts with
    ///      a coded error when the result does not fit in uint256 (fail
    ///      closed). d is never 0 here (10**k * 1e12).
    function _mulDivFloor(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) {
            return prod0 / d;
        }
        require(d > prod1, "VF-ORC-004: valuation out of range");
        unchecked {
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = prod0 * inverse;
        }
    }

    /// @dev Price (30-decimal USD, VF-ORC-016) of the last record posted strictly before
    ///      `timestamp`; 0 when there is none or that record is a failed run.
    function _priceInEffectAt(bytes32 assetKey, uint256 timestamp) internal view returns (uint256) {
        PricePoint[] storage h = _priceHistory[assetKey];
        uint256 lo = 0;
        uint256 hi = h.length;
        // First index whose postedAt >= timestamp.
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (uint256(h[mid].postedAt) < timestamp) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return 0;
        return uint256(h[lo - 1].priceUsd30);
    }

    /// @notice Scheduled price record in effect for a lock created at
    ///         `timestamp` (0 means unavailable).
    function priceInEffectAt(
        string calldata environmentId,
        bytes32 canonicalAssetId,
        uint256 timestamp
    ) external view returns (uint256) {
        return _priceInEffectAt(_assetKey(environmentId, canonicalAssetId), timestamp);
    }

    function priceHistoryLength(bytes32 assetKey) external view returns (uint256) {
        return _priceHistory[assetKey].length;
    }

    function priceHistoryAt(bytes32 assetKey, uint256 index)
        external
        view
        returns (uint256 priceUsd30, uint64 postedAt, uint64 runId)
    {
        PricePoint memory p = _priceHistory[assetKey][index];
        return (uint256(p.priceUsd30), p.postedAt, p.runId);
    }

    /// @dev VF-ORC-011/013: days since launch from Valuation Timestamp (source block time).
    function _daysSinceLaunchFromValuation(uint256 valuationTimestamp) internal view returns (uint256) {
        uint256 launch = protocolLaunchTimestamp;
        if (launch == 0 || valuationTimestamp <= launch) {
            return 0;
        }
        return (valuationTimestamp - launch) / 1 days;
    }

    // ===== Issuance calculation (BASE-ISSUE + BASE-EMIT + BASE-MULT) =====
    // VF-COM-018: order = USD × emission × asset_mult × duration_mult
    // VF-COM-019: every division floors; factors may not be reordered.

    function _computeIssuance(
        uint256 verifiedGrossUsdMicro,
        uint8 outputToken,
        uint8 custodyClass,
        uint256 durationSecs,
        uint256 daysSinceLaunch
    ) internal pure returns (uint256) {
        // Emission rate with decay
        uint256 emissionRate = _computeEmissionRate(outputToken, daysSinceLaunch);

        // Step 1: USD × emission rate
        uint256 step = (verifiedGrossUsdMicro * emissionRate) / SCALE;

        // Step 2: × asset multiplier
        uint16 assetBps = custodyClass == 1 ? S1_MULTIPLIER_BPS
                        : custodyClass == 2 ? S2_MULTIPLIER_BPS
                        : S3_MULTIPLIER_BPS;
        uint256 assetMultFp = (SCALE * assetBps) / 10000;
        step = (step * assetMultFp) / SCALE;

        // Step 3: × duration multiplier
        uint32 durBps = _getDurationMultiplierBps(durationSecs);
        require(durBps > 0, "VF-COM-002: duration not permitted");
        uint256 durMultFp = (SCALE * durBps) / 10000;
        step = (step * durMultFp) / SCALE;

        return step;
    }

    function _computeEmissionRate(uint8 outputToken, uint256 daysSinceLaunch) internal pure returns (uint256) {
        uint256 initialRate = outputToken == 0 ? VCLM_INITIAL_RATE : CHONX_INITIAL_RATE;
        uint256 floorRate = outputToken == 0 ? VCLM_FLOOR_RATE : CHONX_FLOOR_RATE;

        uint256 periods = daysSinceLaunch / DECAY_PERIOD_DAYS;
        uint256 rate = initialRate;
        for (uint256 i = 0; i < periods; i++) {
            rate = (rate * DECAY_SURVIVAL_FP) / SCALE;
            if (rate <= floorRate) {
                rate = floorRate;
                break;
            }
        }
        if (rate < floorRate) rate = floorRate;
        return rate;
    }

    // Permitted durations: the sixteen COMMITMENT_DURATIONS rows. Exact match.
    function _isPermittedDuration(uint256 secs) internal pure returns (bool) {
        return CommitmentDurations.multiplierBps(secs) != 0;
    }

    function _getDurationMultiplierBps(uint256 secs) internal pure returns (uint32) {
        return uint32(CommitmentDurations.multiplierBps(secs));
    }

    // ===== View functions =====

    function isLockConsumed(string calldata envId, bytes32 lockId) external view returns (bool) {
        return consumedLocks[keccak256(abi.encodePacked(envId, lockId))];
    }

    /// @notice True once the lock's RAC is recorded. Takes racKey(env, lockId).
    function isRacRecorded(bytes32 key) external view returns (bool) {
        return recordedRacs[key];
    }

    function isLockRacRecorded(string calldata envId, bytes32 lockId) external view returns (bool) {
        return recordedRacs[racKey(envId, lockId)];
    }

    function getRemainingVclmCap() external view returns (uint256) {
        uint256 issued = lifetimeVclmIssued();
        return issued >= VCLM_HARD_CAP ? 0 : VCLM_HARD_CAP - issued;
    }

    /// @notice VCLM minted as Treasury Reward Stake rewards (0 before VCLM
    ///         has a stake minter).
    function stakeRewardVclmIssued() public view returns (uint256) {
        address stake = vclmToken.minterStake();
        if (stake == address(0)) return 0;
        return IStakeRewardView(stake).cumulativeRewardVclmMinted();
    }

    /// @notice VF-SUP-001/002, VF-TOK-002: lifetime VCLM = Commitment Vault
    ///         issuance + Treasury Reward Stake rewards. It is used for the
    ///         hard cap and for CHONX activation: every legitimate protocol
    ///         mint counts (operator t264u).
    function lifetimeVclmIssued() public view returns (uint256) {
        return cumulativeVclmIssued + stakeRewardVclmIssued();
    }

    /// @notice VF-TOK-002: permanent CHONX activation once lifetime VCLM
    ///         (locks and stake rewards) reaches 10,000,000. Anyone may call
    ///         it, so activation does not wait for the next lock when stake
    ///         rewards crossed the threshold. It only ever sets the flag once.
    function syncChonxActivation() external {
        _syncChonxActivation();
    }

    function _syncChonxActivation() internal {
        if (!chonxActivated && lifetimeVclmIssued() >= CHONX_ACTIVATION_THRESHOLD) {
            chonxActivated = true;
            chonxActivationBlock = block.number;
            chonxActivationTimestamp = block.timestamp;
            emit ChonxActivated(block.number);
        }
    }

    /// @notice Section 10.2 epoch number now (1-indexed); 0 before launch.
    function currentEpoch() public view returns (uint256) {
        uint256 t0 = protocolLaunchTimestamp;
        if (t0 == 0 || block.timestamp < t0) return 0;
        return ((block.timestamp - t0) / EPOCH_DURATION_SECS) + 1;
    }

    function getRemainingChonxCap() external view returns (uint256) {
        return CHONX_HARD_CAP - cumulativeChonxIssued;
    }

    function previewEmissionRate(uint8 outputToken, uint256 daysSinceLaunch) external pure returns (uint256) {
        return _computeEmissionRate(outputToken, daysSinceLaunch);
    }

    function previewIssuance(
        uint256 verifiedGrossUsdMicro,
        uint8 outputToken,
        uint8 custodyClass,
        uint256 durationSecs,
        uint256 daysSinceLaunch
    ) external pure returns (uint256) {
        return _computeIssuance(
            verifiedGrossUsdMicro,
            outputToken,
            custodyClass,
            durationSecs,
            daysSinceLaunch
        );
    }
}
