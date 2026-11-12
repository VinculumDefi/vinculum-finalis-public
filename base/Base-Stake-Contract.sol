// =============================================================================
// VinculumFinalisStake — Treasury Reward Stake + Epoch Contract
// (BASE-STAKE + BASE-EPOCH)
//
// PROVENANCE: Built directly from Revision 6 authoritative documents:
//   - 227826f11_Vinculum_Finalis_Master_Specification_Revision_6_2026-07-28.docx (Revision 6)
//   - Vinculum_Finalis_Protocol_Constants.json (Revision 6, 2026-07-28)
//   - Vinculum_Finalis_Architecture_Design.md (Section A.16, B.11)
//
// Requirements implemented:
//   VF-STK-001: Stake active from launch (not dependent on CHONX activation)
//   VF-STK-002: Only VCLM/CHONX/SYNTH stakable
//   VF-STK-003: Only listed token+duration multipliers apply
//   VF-STK-004: Rewards paid only in newly minted VCLM
//   VF-STK-005: S1/S2/S3 never affects Weight
//   VF-STK-006: Every epoch = exactly 10 days
//   VF-STK-007: Credit belongs to epoch recorded
//   VF-STK-008: Permissionless finalization
//   VF-STK-009: Delayed finalization never shifts boundaries
//   VF-STK-010: Pending epochs finalized in chronological order
//   VF-STK-011: Position beginning after epoch start does not qualify
//   VF-STK-012: Position expiring before end of N+1 does not qualify
//   VF-STK-013: Entitlement fixed only after scheduled end of N+1
//   VF-STK-014: Single mint to stake contract; proportional entitlements
//   VF-STK-015: Zero-eligible epoch mints nothing
//   VF-STK-016: Claimable VCLM accumulates and never expires
//   VF-STK-017: User may claim all in one tx
//   VF-STK-018: Claims transfer minted VCLM; no re-mint
//   VF-STK-019: Claims only to owner
//   VF-STK-020: Withdrawal does not erase claimable
//   VF-STK-021: Queue one future term 30/60/90/120d
//   VF-STK-022: Queued term begins at scheduled end of current
//   VF-STK-023: Only one future term at a time
//   VF-STK-024: Extension adds/removes no tokens, charges no fee
//   VF-STK-025: Without extension position inactive at maturity
//   VF-STK-026: Proportional share; rounds down to base unit
//   VF-STK-027: Microscopic remainder inaccessible
//   VF-STK-028: Epoch reward exceeding capacity mints nothing
//   VF-STK-029: At zero VCLM capacity stake closes to new positions
//   VF-STK-030: At terminal state staked tokens withdrawable
//   VF-STK-031: Position requires positive nonzero token amount
//   VF-RAC-004: Epoch Reward Basis = sum of RAC closed in epoch
//   VF-RAC-005: Permanent $0.10 Reward Reference Value
//   VF-RAC-006: Credit becomes Used only at allocation
//   VF-RAC-003/004 + VF-STK-007 (t262u): Epoch Reward Basis is read from the
//               Verifier's per-epoch RAC total (epochRewardBasis), on the same
//               launch-based epochs (Section 10.2, T0 = Verifier
//               protocolLaunchTimestamp, set at finalize).
//   VF-SUP-002, VF-TOK-002 (t264u): reward VCLM is counted in the Verifier's
//               lifetime VCLM (cumulativeRewardVclmMinted, read by the
//               Verifier), which is used for the cap and for the 10,000,000
//               CHONX activation threshold (operator t264u).
//   t269u: bounded gas. closeEpoch and allocateEpoch are O(1): each epoch's
//               total weight is kept incrementally (a running sum with
//               scheduled additions and removals at the epochs where a
//               position's eligibility or duration multiplier changes).
//               Rewards are claimed per position over a caller-chosen epoch
//               range. The reward of every position in every epoch is exactly
//               the earlier design's floor(epoch reward x weight / total
//               weight), with the same weight rule (_epochWeight, unchanged)
//               and the same term rule (multiplier in force at the start of
//               epoch N, operator approved t269u).
//
// SPDX-License-Identifier: PROTOCOL-RESTRICTED
// Solidity 0.8.19+
// =============================================================================

pragma solidity 0.8.19;

interface IVerifier {
    function cumulativeVclmIssued() external view returns (uint256);
    function lifetimeVclmIssued() external view returns (uint256);
    function epochRewardBasis(uint256 epochN) external view returns (uint256);
    function protocolLaunchTimestamp() external view returns (uint256);
}

interface IStakeToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IVclmToken is IStakeToken {
    function mint(address to, uint256 amount) external;
}

contract VinculumFinalisStake {

    // ===== Protocol constants =====

    uint256 public constant SCALE = 1e18;
    uint256 public constant VCLM_HARD_CAP = 10_000_000_000 * 1e18;

    // VF-STK-006 / VF-RAC-003: Epoch = 10 days
    uint256 public constant EPOCH_DURATION_SECS = 10 * 1 days;

    // VF-RAC-005: Permanent $0.10 Reward Reference Value
    uint256 public constant REWARD_REFERENCE_CENTS = 10;

    // VF-STK-003: independent four-duration stake table (TRS correction,
    // 2026-10-17). Not the Commitment Vault lock durations.
    //   30 days  = 10000 bps (1.00x)
    //   60 days  = 14000 bps (1.40x)
    //   90 days  = 17500 bps (1.75x)
    //   120 days = 21000 bps (2.10x)
    // Historical Solidity used 20000 bps (2.00x) for 120 days. The operator
    // authorized 21000 bps (2.10x) on 2026-10-17. Any other duration reverts.
    uint256 public constant STAKE_30D_SECS  = 30 days;
    uint256 public constant STAKE_60D_SECS  = 60 days;
    uint256 public constant STAKE_90D_SECS  = 90 days;
    uint256 public constant STAKE_120D_SECS = 120 days;
    uint32 public constant STAKE_30D_BPS  = 10000;
    uint32 public constant STAKE_60D_BPS  = 14000;
    uint32 public constant STAKE_90D_BPS  = 17500;
    uint32 public constant STAKE_120D_BPS = 21000;
    uint256 public constant STAKE_DURATION_COUNT = 4;

    // Token multipliers stay VCLM=1.0x, CHONX=2.0x, SYNTH=4.0x (bps).
    uint16 private constant TOKEN_VCLM_BPS  = 10000;
    uint16 private constant TOKEN_CHONX_BPS = 20000;
    uint16 private constant TOKEN_SYNTH_BPS = 40000;

    // ===== Storage =====

    // Immutable wiring (no setter). T0 is not stored here: Section 10.2 says
    // protocol launch defines T0, and the Verifier records protocol launch at
    // finalize (protocolLaunchTimestamp). Both contracts use that one value.
    IVclmToken public immutable vclmToken;
    IStakeToken public immutable chonxToken;
    IStakeToken public immutable synthToken;
    IVerifier public immutable verifier;

    bool public terminalState;

    // VF-SUP-002: VCLM minted by this contract as epoch rewards. Counted in
    // lifetime VCLM (Verifier.lifetimeVclmIssued) for the hard cap only.
    uint256 public cumulativeRewardVclmMinted;

    struct Position {
        address owner;
        uint8 token;      // 0=VCLM, 1=CHONX, 2=SYNTH
        uint256 amount;
        uint256 durationSecs;     // current term length
        uint256 startTimestamp;   // current term start
        uint256 endTimestamp;     // current term scheduled end
        uint32 multiplierBps;     // current term multiplier
        uint32 queuedExtensionBps;  // 0 = no extension
        uint256 queuedExtensionSecs;
        bool withdrawn;
        uint256 activeSince;      // first term start; unchanged by extensions
        uint256 withdrawnAt;      // 0 until withdrawn
    }

    // Term history: start time and multiplier of every term of a position,
    // so a delayed epoch uses the multiplier in force for that epoch.
    struct Term {
        uint256 start;
        uint32 multiplierBps;
    }

    mapping(uint256 => Position) public positions;
    mapping(uint256 => Term[]) private _terms;
    uint256 public nextPositionId;

    struct Epoch {
        bool closed;
        bool allocated;
        uint256 rewardBasis;      // VF-RAC-004, USD 18 decimals
        uint256 totalWeight;
        uint256 mintedVclm;       // complete Epoch Reward VCLM minted (VF-STK-014)
        uint256 closeTimestamp;
        uint256 allocateTimestamp;
    }

    mapping(uint256 => Epoch) public epochs;

    // t269u: incremental epoch total weight. runningWeight[N] is final for
    // every closed epoch except while N+1 has not ended (a change that can
    // still reach N is applied to runningWeight[N] directly). For unclosed
    // epochs, weightAddAt / weightSubAt hold the scheduled changes.
    mapping(uint256 => uint256) private _runningWeight;
    mapping(uint256 => uint256) private _weightAddAt;
    mapping(uint256 => uint256) private _weightSubAt;
    uint256 public lastClosedEpoch;
    // t270u(g): last allocated epoch; allocation is in strict epoch order.
    uint256 public lastAllocatedEpoch;

    // VF-STK-016: Claimable VCLM accumulates and never expires: a position's
    // unclaimed epochs stay claimable from nextClaimEpoch onwards.
    mapping(uint256 => uint256) public nextClaimEpoch;

    // t270u: per-position term checkpoint. The term in force at the start of
    // nextClaimEpoch (or an earlier one). Terms are only appended, so a claim
    // resumes the term walk here instead of at the first term: claim work
    // depends only on the epochs and terms in the claimed range.
    mapping(uint256 => uint256) private _claimTermIdx;

    // ===== Events =====

    event PositionCreated(uint256 indexed positionId, address indexed owner, uint8 token, uint256 amount, uint256 durationSecs);
    event ExtensionQueued(uint256 indexed positionId, uint256 durationSecs);
    event PositionExtended(uint256 indexed positionId, uint256 newEndTimestamp);
    event PositionWithdrawn(uint256 indexed positionId);
    event EpochClosed(uint256 indexed epoch, uint256 rewardBasis, uint256 totalWeight);
    event EpochAllocated(uint256 indexed epoch, uint256 mintedVclm, uint256 totalWeight);
    event VclmClaimed(uint256 indexed positionId, address indexed owner, uint256 fromEpoch, uint256 toEpoch, uint256 amount);
    event TerminalStateEntered();

    constructor(
        address _vclmToken,
        address _chonxToken,
        address _synthToken,
        address _verifier
    ) {
        require(_vclmToken != address(0), "VF-DEP-002: zero VCLM");
        require(_chonxToken != address(0), "VF-DEP-002: zero CHONX");
        require(_synthToken != address(0), "VF-DEP-002: zero SYNTH");
        require(_verifier != address(0), "VF-DEP-002: zero verifier");
        vclmToken = IVclmToken(_vclmToken);
        chonxToken = IStakeToken(_chonxToken);
        synthToken = IStakeToken(_synthToken);
        verifier = IVerifier(_verifier);
    }

    /// @notice T0 (Section 10.2): the Verifier's protocol launch time, set once
    ///         at finalize. Zero before finalize.
    function launchTimestamp() public view returns (uint256) {
        return verifier.protocolLaunchTimestamp();
    }

    function _launched() internal view returns (uint256 t0) {
        t0 = verifier.protocolLaunchTimestamp();
        require(t0 > 0, "VF-STK-001: protocol not launched");
    }

    function _remainingVclmCapacity() internal view returns (uint256) {
        uint256 issued = verifier.lifetimeVclmIssued();
        return issued >= VCLM_HARD_CAP ? 0 : VCLM_HARD_CAP - issued;
    }

    function _enterTerminalIfCapReached() internal returns (bool) {
        if (terminalState) return true;
        if (_remainingVclmCapacity() == 0) {
            terminalState = true;
            emit TerminalStateEntered();
            return true;
        }
        return false;
    }

    // ===== VF-STK-001/002/031: Create stake position =====

    function createPosition(uint8 token, uint256 amount, uint256 durationSecs) external returns (uint256) {
        uint256 t0 = _launched();
        // VF-STK-029: Terminal state, no new positions
        require(!_enterTerminalIfCapReached(), "VF-STK-029: terminal state");

        // VF-STK-002: Only VCLM/CHONX/SYNTH
        require(token <= 2, "VF-STK-002: invalid token");

        // VF-STK-031: Positive nonzero amount
        require(amount > 0, "VF-STK-031: zero amount");

        // VF-STK-003: Only listed durations
        uint32 multBps = _getStakeMultiplier(durationSecs);
        require(multBps > 0, "VF-STK-003: duration not permitted");

        IStakeToken stakeToken = _tokenOf(token);
        uint256 beforeBal = stakeToken.balanceOf(address(this));
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "VFS: transfer failed");
        require(stakeToken.balanceOf(address(this)) - beforeBal == amount, "VFS: received amount mismatch");

        uint256 id = nextPositionId++;
        uint256 start = block.timestamp;
        positions[id] = Position({
            owner: msg.sender,
            token: token,
            amount: amount,
            durationSecs: durationSecs,
            startTimestamp: start,
            endTimestamp: start + durationSecs,
            multiplierBps: multBps,
            queuedExtensionBps: 0,
            queuedExtensionSecs: 0,
            withdrawn: false,
            activeSince: start,
            withdrawnAt: 0
        });
        _terms[id].push(Term({start: start, multiplierBps: multBps}));

        // t269u: schedule this position's weight for every epoch it qualifies
        // for (VF-STK-011/012): starts at or after activeSince, N+1 ends by
        // the scheduled end.
        uint256 first = _firstEpochAtOrAfter(start, t0);
        nextClaimEpoch[id] = first;
        _applyWeight(id, first, _lastEligibleBy(start + durationSecs, t0), true, t0);

        emit PositionCreated(id, msg.sender, token, amount, durationSecs);
        return id;
    }

    // ===== VF-STK-021/022/023/024: Queue extension =====

    function queueExtension(uint256 positionId, uint256 durationSecs) external {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "VFS: not owner");
        require(!pos.withdrawn, "VFS: withdrawn");
        // VF-STK-029: Terminal state closes extensions
        require(!_enterTerminalIfCapReached(), "VF-STK-029: terminal state");

        // CL-14 / VF-STK-021: extensions may only be queued while the position
        // is ACTIVE. VF-STK-025 forbids an expired position retroactively
        // covering an inactivity gap.
        require(block.timestamp < pos.endTimestamp, "VF-STK-025: position not active");

        // VF-STK-023: Only one future term at a time
        require(pos.queuedExtensionBps == 0, "VF-STK-023: already queued");

        uint32 multBps = _getStakeMultiplier(durationSecs);
        require(multBps > 0, "VF-STK-003: duration not permitted");

        // VF-STK-024: Extension adds/removes no tokens, charges no fee
        uint256 t0 = _launched();
        uint256 oldLast = _lastEligibleBy(pos.endTimestamp, t0);
        pos.queuedExtensionBps = multBps;
        pos.queuedExtensionSecs = durationSecs;

        // t269u: the epochs the queued term adds (VF-STK-022). Each gets the
        // multiplier in force at its start, so the queued term applies only
        // from the first epoch starting at or after the current term's end.
        uint256 from = _firstEpochAtOrAfter(pos.activeSince, t0);
        if (oldLast + 1 > from) from = oldLast + 1;
        _applyWeight(positionId, from, _lastEligibleBy(pos.endTimestamp + durationSecs, t0), true, t0);
        emit ExtensionQueued(positionId, durationSecs);
    }

    /// @notice Records a queued term that has begun (VF-STK-022: it begins at
    ///         the scheduled end of the current term whether or not this is
    ///         called; eligibility already counts it). Lets a further term be
    ///         queued (VF-STK-023).
    function applyExtensionIfMatured(uint256 positionId) external {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "VFS: not owner");
        require(!pos.withdrawn, "VFS: withdrawn");
        require(pos.queuedExtensionBps > 0, "VFS: no queued extension");
        require(block.timestamp >= pos.endTimestamp, "VFS: not matured");

        // VF-STK-022: Queued term begins at scheduled end of current
        pos.startTimestamp = pos.endTimestamp;
        pos.durationSecs = pos.queuedExtensionSecs;
        pos.endTimestamp = pos.startTimestamp + pos.queuedExtensionSecs;
        pos.multiplierBps = pos.queuedExtensionBps;
        pos.queuedExtensionBps = 0;
        pos.queuedExtensionSecs = 0;
        _terms[positionId].push(Term({start: pos.startTimestamp, multiplierBps: pos.multiplierBps}));
        emit PositionExtended(positionId, pos.endTimestamp);
    }

    // ===== VF-STK-025/030: Withdrawal =====

    function withdrawPosition(uint256 positionId) external {
        Position storage pos = positions[positionId];
        require(pos.owner == msg.sender, "VFS: not owner");
        require(!pos.withdrawn, "VFS: withdrawn");
        // CL-15 / VF-STK-030: at terminal state all staked tokens become
        // IMMEDIATELY withdrawable, matured or not.
        if (!_enterTerminalIfCapReached()) {
            // A queued term that has begun keeps the tokens staked (VF-STK-022).
            require(block.timestamp >= _scheduledEnd(pos), "VFS: not matured");
        }

        // t269u: an early withdrawal (terminal state only) removes the weight
        // of every epoch whose N+1 has not ended (VF-STK-012). A withdrawal at
        // or after the scheduled end removes nothing.
        {
            uint256 t0 = _launched();
            uint256 from = _firstEpochAtOrAfter(pos.activeSince, t0);
            uint256 keptLast = _lastEligibleBy(block.timestamp, t0);
            if (keptLast + 1 > from) from = keptLast + 1;
            _applyWeight(positionId, from, _lastEligibleBy(_scheduledEnd(pos), t0), false, t0);
        }

        pos.withdrawn = true;
        pos.withdrawnAt = block.timestamp;

        IStakeToken stakeToken = _tokenOf(pos.token);
        require(stakeToken.transfer(pos.owner, pos.amount), "VFS: return failed");

        // VF-STK-020: Withdrawal does not erase claimable VCLM
        emit PositionWithdrawn(positionId);
    }

    // ===== BASE-EPOCH Phase 1: Close (VF-RAC-003/004, VF-STK-006-010) =====

    /// @notice Finalizes epoch N after its scheduled end (VF-STK-008) and fixes
    ///         its Epoch Reward Basis from the Verifier (VF-RAC-004). No credit
    ///         can be added to N after it ends (VF-STK-007): the Verifier
    ///         assigns each credit to the epoch in which it is recorded.
    function closeEpoch(uint256 epochN) external {
        uint256 t0 = _launched();
        Epoch storage ep = epochs[epochN];
        require(!ep.closed, "VFS: already closed");

        // CL-22: epochs are 1-indexed.
        require(epochN >= 1, "VF-STK-010: epoch numbering begins at 1");

        // VF-STK-008/009: only after the scheduled end; boundaries never move.
        require(block.timestamp >= t0 + epochN * EPOCH_DURATION_SECS, "VF-STK-008: epoch not ended");

        // VF-STK-010: Chronological order
        if (epochN > 1) {
            require(epochs[epochN - 1].closed, "VF-STK-010: chronological order");
        }

        ep.rewardBasis = verifier.epochRewardBasis(epochN);
        ep.closed = true;
        ep.closeTimestamp = block.timestamp;

        // t269u: O(1). Materialize the running total weight for N.
        uint256 w = (_runningWeight[epochN - 1] + _weightAddAt[epochN]) - _weightSubAt[epochN];
        _runningWeight[epochN] = w;
        lastClosedEpoch = epochN;
        emit EpochClosed(epochN, ep.rewardBasis, w);
    }

    // ===== BASE-EPOCH Phase 2: Allocate (VF-STK-013-015/026-028, VF-RAC-005/006, VF-SUP-009) =====

    function allocateEpoch(uint256 epochN) external {
        uint256 t0 = _launched();
        // VF-STK-008: Permissionless
        Epoch storage ep = epochs[epochN];
        require(ep.closed, "VFS: not closed");
        require(!ep.allocated, "VFS: already allocated");

        // VF-STK-013: Only after scheduled end of N+1
        uint256 nPlus1End = t0 + ((epochN + 1) * EPOCH_DURATION_SECS);
        require(block.timestamp >= nPlus1End, "VF-STK-013: wait for N+1 end");

        // VF-STK-010 + operator rule t270u(g): permissionless chronological
        // allocation. Epoch N is allocated only after N-1 (epoch 1 first).
        // Every outcome below (zero RAC, zero weight, cap skip, paid) marks the
        // epoch allocated, so the next epoch can always follow: no deadlock.
        require(epochN == lastAllocatedEpoch + 1, "VF-STK-010: allocate in epoch order (t270u)");
        lastAllocatedEpoch = epochN;

        // Weight is fixed now (VF-STK-013): no change can reach N once N+1
        // has ended. t269u: O(1), the incrementally kept total.
        uint256 totalWeight = _runningWeight[epochN];
        ep.totalWeight = totalWeight;

        // VF-RAC-006 / VF-STK-015: from here the epoch's credits are used.
        ep.allocated = true;
        ep.allocateTimestamp = block.timestamp;

        // VF-STK-015: Zero-eligible epoch mints nothing, carries nothing forward.
        if (ep.rewardBasis == 0 || totalWeight == 0) {
            emit EpochAllocated(epochN, 0, 0);
            return;
        }

        // VF-RAC-005: Epoch Reward VCLM = Epoch Reward Basis / $0.10
        uint256 totalReward = (ep.rewardBasis * 100) / REWARD_REFERENCE_CENTS;

        // VF-STK-028 / VF-SUP-009: the complete reward must fit, else mint nothing.
        uint256 remaining = _remainingVclmCapacity();
        if (remaining == 0) {
            _enterTerminalIfCapReached(); // VF-STK-029 / VF-SUP-011
            emit EpochAllocated(epochN, 0, 0);
            return;
        }
        if (totalReward > remaining) {
            emit EpochAllocated(epochN, 0, 0);
            return;
        }

        // VF-STK-014: the complete Epoch Reward VCLM is minted once to this contract.
        cumulativeRewardVclmMinted += totalReward;
        ep.mintedVclm = totalReward;
        vclmToken.mint(address(this), totalReward);

        // VF-STK-014/026: proportional entitlements, each rounded down, are
        // taken per position at claim (claimPosition).
        // VF-STK-027: the remainder stays in this contract, never reused.

        emit EpochAllocated(epochN, totalReward, totalWeight);
        _enterTerminalIfCapReached(); // VF-SUP-011 if this reward used the last capacity
    }

    // ===== VF-STK-016/017/018/019/026: Claim =====

    /// @notice Claims a position's VCLM for its unclaimed epochs up to toEpoch.
    ///         Each epoch pays floor(epoch reward x weight / total weight)
    ///         (VF-STK-026). toEpoch must be final (its N+1 has ended) and
    ///         every epoch the position qualifies for in the range must be
    ///         allocated. The caller chooses the range, so gas is bounded.
    function claimPosition(uint256 positionId, uint256 toEpoch) public returns (uint256 amount) {
        Position storage pos = positions[positionId];
        // VF-STK-019: Only to owner
        require(pos.owner == msg.sender, "VFS: not owner");
        uint256 t0 = _launched();
        uint256 from = nextClaimEpoch[positionId];
        require(toEpoch >= from, "VFS: nothing to claim");
        uint256 k;
        (amount, k) = _claimable(positionId, from, toEpoch, t0, true, _claimTermIdx[positionId]);
        nextClaimEpoch[positionId] = toEpoch + 1;
        if (k != _claimTermIdx[positionId]) _claimTermIdx[positionId] = k;
        if (amount > 0) {
            // VF-STK-018: Transfer minted VCLM; no re-mint
            require(vclmToken.transfer(msg.sender, amount), "VFS: transfer failed");
        }
        emit VclmClaimed(positionId, msg.sender, from, toEpoch, amount);
    }

    /// @notice VF-STK-017: claim several positions in one transaction.
    function claimPositions(uint256[] calldata positionIds, uint256 toEpoch) external returns (uint256 total) {
        for (uint256 i = 0; i < positionIds.length; i++) {
            if (nextClaimEpoch[positionIds[i]] <= toEpoch) total += claimPosition(positionIds[i], toEpoch);
        }
    }

    /// @notice VCLM a position could claim now for epochs up to toEpoch.
    function claimableVclm(uint256 positionId, uint256 toEpoch) external view returns (uint256) {
        uint256 t0 = verifier.protocolLaunchTimestamp();
        uint256 from = nextClaimEpoch[positionId];
        if (t0 == 0 || toEpoch < from || positions[positionId].owner == address(0)) return 0;
        (uint256 amount, ) = _claimable(positionId, from, toEpoch, t0, false, _claimTermIdx[positionId]);
        return amount;
    }

    // Sum over epochs from..toEpoch of floor(mintedVclm x weight / totalWeight).
    // Weight is the earlier design's _epochWeight, evaluated with a forward
    // term pointer that starts at the position's checkpoint k0 (t270u).
    function _claimable(uint256 positionId, uint256 from, uint256 toEpoch, uint256 t0, bool strict, uint256 k0)
        internal view returns (uint256 amount, uint256 k)
    {
        // VF-STK-013: only epochs whose N+1 has ended are final.
        if (strict) require(block.timestamp >= t0 + (toEpoch + 1) * EPOCH_DURATION_SECS, "VF-STK-013: epoch not final");
        Position storage pos = positions[positionId];
        uint256 last = _lastEligibleBy(_scheduledEnd(pos), t0);
        if (pos.withdrawn) {
            uint256 wLast = _lastEligibleBy(pos.withdrawnAt, t0);
            if (wLast < last) last = wLast;
        }
        if (toEpoch < last) last = toEpoch;
        Term[] storage ts = _terms[positionId];
        uint256 nTerms = ts.length + (pos.queuedExtensionBps > 0 ? 1 : 0);
        k = k0;
        uint256 base = pos.amount * _getTokenMultiplier(pos.token);
        for (uint256 n = from; n <= last; n++) {
            Epoch storage ep = epochs[n];
            if (!ep.allocated) {
                if (strict) revert("VFS: epoch not allocated");
                continue;
            }
            if (ep.mintedVclm == 0) continue;
            uint256 t = t0 + (n - 1) * EPOCH_DURATION_SECS;
            while (k + 1 < nTerms && _termStart(positionId, k + 1) <= t) k++;
            uint256 weight = (base * _termMult(positionId, k)) / 1e8;
            amount += (ep.mintedVclm * weight) / ep.totalWeight;
        }
    }

    function _termStart(uint256 positionId, uint256 k) internal view returns (uint256) {
        Term[] storage ts = _terms[positionId];
        return k < ts.length ? ts[k].start : positions[positionId].endTimestamp;
    }

    function _termMult(uint256 positionId, uint256 k) internal view returns (uint256) {
        Term[] storage ts = _terms[positionId];
        return k < ts.length ? ts[k].multiplierBps : positions[positionId].queuedExtensionBps;
    }

    // t269u: first epoch whose start is at or after t (Section 10.2).
    function _firstEpochAtOrAfter(uint256 t, uint256 t0) internal pure returns (uint256) {
        if (t <= t0) return 1;
        return (t - t0 + EPOCH_DURATION_SECS - 1) / EPOCH_DURATION_SECS + 1;
    }

    // t269u: last epoch N whose N+1 ends at or before T (0 if none).
    function _lastEligibleBy(uint256 T, uint256 t0) internal pure returns (uint256) {
        if (T < t0 + 2 * EPOCH_DURATION_SECS) return 0;
        return (T - t0) / EPOCH_DURATION_SECS - 1;
    }

    // t269u: add (or remove) the position's weight for epochs a..b, each with
    // the duration multiplier in force at the epoch's start: terms (and a
    // queued term starting at the current term's end) are walked from the
    // last back, stopping once the range is covered.
    function _applyWeight(uint256 positionId, uint256 a, uint256 b, bool add, uint256 t0) internal {
        if (a == 0 || a > b) return;
        Position storage pos = positions[positionId];
        uint256 base = pos.amount * _getTokenMultiplier(pos.token);
        uint256 k = _terms[positionId].length + (pos.queuedExtensionBps > 0 ? 1 : 0);
        uint256 hi = b;
        while (k > 0) {
            k--;
            uint256 lo = _firstEpochAtOrAfter(_termStart(positionId, k), t0);
            if (lo <= hi) {
                uint256 segFrom = lo > a ? lo : a;
                _rangeWeight(segFrom, hi, (base * _termMult(positionId, k)) / 1e8, add);
            }
            if (lo <= a) break;
            hi = lo - 1;
        }
    }

    // Apply w to epochs from..to. Closed epochs (at most the one whose N+1 is
    // still running) are changed directly; the last closed total carries
    // forward to later epochs through the running sum, so only the end of the
    // range needs a scheduled reverse change. Unclosed ranges are scheduled.
    function _rangeWeight(uint256 from, uint256 to, uint256 w, bool add) internal {
        if (w == 0 || from > to) return;
        uint256 closedTo = lastClosedEpoch;
        if (from <= closedTo) {
            uint256 upTo = to < closedTo ? to : closedTo;
            for (uint256 i = from; i <= upTo; i++) {
                _runningWeight[i] = add ? _runningWeight[i] + w : _runningWeight[i] - w;
            }
            if (to < closedTo) return;
        } else {
            if (add) _weightAddAt[from] += w; else _weightSubAt[from] += w;
        }
        if (add) _weightSubAt[to + 1] += w; else _weightAddAt[to + 1] += w;
    }

    // ===== Views =====

    /// @notice Current total weight kept for epoch N (final once N+1 has ended).
    function epochTotalWeight(uint256 epochN) external view returns (uint256) {
        if (epochN <= lastClosedEpoch) return _runningWeight[epochN];
        uint256 w = _runningWeight[lastClosedEpoch];
        for (uint256 n = lastClosedEpoch + 1; n <= epochN; n++) w = (w + _weightAddAt[n]) - _weightSubAt[n];
        return w;
    }

    // CL-23: returns 0 before launch rather than underflowing.
    function getCurrentEpoch() external view returns (uint256) {
        uint256 t0 = verifier.protocolLaunchTimestamp();
        if (t0 == 0 || block.timestamp < t0) return 0;
        return ((block.timestamp - t0) / EPOCH_DURATION_SECS) + 1;
    }

    function stakeDurationCount() external pure returns (uint256) {
        return STAKE_DURATION_COUNT;
    }

    function stakeMultiplierBps(uint256 durationSecs) external pure returns (uint256) {
        return _getStakeMultiplier(durationSecs);
    }

    function termCount(uint256 positionId) external view returns (uint256) {
        return _terms[positionId].length;
    }

    /// @notice Weight a position earns for epoch N (0 if it does not qualify).
    function epochWeight(uint256 positionId, uint256 epochN) external view returns (uint256) {
        uint256 t0 = verifier.protocolLaunchTimestamp();
        if (t0 == 0 || epochN == 0) return 0;
        return _epochWeight(positionId, epochN, t0);
    }

    // Four rows only; any other duration reverts (VF-STK-003).
    function _getStakeMultiplier(uint256 durationSecs) internal pure returns (uint32) {
        if (durationSecs == STAKE_30D_SECS) return STAKE_30D_BPS;
        if (durationSecs == STAKE_60D_SECS) return STAKE_60D_BPS;
        if (durationSecs == STAKE_90D_SECS) return STAKE_90D_BPS;
        if (durationSecs == STAKE_120D_SECS) return STAKE_120D_BPS;
        revert("VF-STK-003: duration not permitted");
    }

    function _tokenOf(uint8 token) internal view returns (IStakeToken) {
        return token == 0 ? IStakeToken(address(vclmToken)) : (token == 1 ? chonxToken : synthToken);
    }

    // Scheduled end including a queued term (VF-STK-022: it begins at the
    // scheduled end of the current term).
    function _scheduledEnd(Position storage pos) internal view returns (uint256) {
        return pos.endTimestamp + (pos.queuedExtensionBps > 0 ? pos.queuedExtensionSecs : 0);
    }

    // Duration multiplier of the term in force at time t.
    function _multiplierAt(uint256 positionId, uint256 t) internal view returns (uint32) {
        Position storage pos = positions[positionId];
        if (pos.queuedExtensionBps > 0 && t >= pos.endTimestamp) return pos.queuedExtensionBps;
        Term[] storage ts = _terms[positionId];
        for (uint256 k = ts.length; k > 0; k--) {
            if (ts[k - 1].start <= t) return ts[k - 1].multiplierBps;
        }
        return 0;
    }

    // CL-03 / Section 10.1: Weight = amount x token multiplier x duration multiplier.
    // Single division floors once; do not split into two divisions.
    // VF-STK-011/012: active at the start of N and through the scheduled end
    // of N+1. Withdrawal before that end removes it. The duration multiplier
    // is the one in force at the start of epoch N.
    function _epochWeight(uint256 positionId, uint256 epochN, uint256 t0) internal view returns (uint256) {
        Position storage pos = positions[positionId];
        if (pos.owner == address(0)) return 0;
        uint256 epochStart = t0 + ((epochN - 1) * EPOCH_DURATION_SECS);
        uint256 nPlus1End = t0 + ((epochN + 1) * EPOCH_DURATION_SECS);
        if (pos.activeSince > epochStart) return 0;
        if (_scheduledEnd(pos) < nPlus1End) return 0;
        if (pos.withdrawn && pos.withdrawnAt < nPlus1End) return 0;
        uint32 durBps = _multiplierAt(positionId, epochStart);
        return (pos.amount * _getTokenMultiplier(pos.token) * durBps) / 1e8;
    }

    // VF-STK-002 bounds token to 0..2; revert rather than default (CL-26).
    function _getTokenMultiplier(uint8 token) internal pure returns (uint32) {
        if (token == 0) return TOKEN_VCLM_BPS;
        if (token == 1) return TOKEN_CHONX_BPS;
        if (token == 2) return TOKEN_SYNTH_BPS;
        revert("VF-STK-002: invalid token");
    }

    // CL-34: Section 10.1 must be observable from outside the contract
    // (weight of the current term).
    function getPositionWeight(uint256 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        require(pos.owner != address(0), "VFS: unknown position");
        return (pos.amount * _getTokenMultiplier(pos.token) * pos.multiplierBps) / 1e8;
    }
}
