// =============================================================================
// BaseCommitmentVaultLock — the Base Commitment Vault (t262u).
//
// Same code as CommitmentVaultLock.sol (the six non-Base EVM chains),
// including the AG-08 per-token accounting, plus one rule:
//   VF-TOK-007 / VF-REG-008: VCLM, CHONX and SYNTH are prohibited Commitment
//     Vault Lock inputs. They exist only on Base. createErc20Lock refuses
//     them as its first check, so no token moves and no fee is taken. The
//     three addresses are constructor immutables: the Base ceremony deploys
//     VCLM, CHONX and the Forge (SYNTH) before this lock. No owner, no setter.
//
// Authority: Vinculum Finalis Master Specification Revision 8 (3 October 2026).
//
//   VF-COM-004 / VF-COM-009 / VF-COM-011 / VF-COM-012 / VF-COM-013
//     Every duration, including the one-hour Trust-Building Handshake,
//     charges 500 bps (5.00%). Fee units are
//     floor(gross * bps / 10_000). Principal is gross minus that fee. A zero
//     fee or a zero principal is rejected before the lock exists.
//   VF-FEE-001 / VF-FEE-006 / VF-FEE-010
//     The fee is paid, in the same asset, to the Dev Fund address supplied at
//     deployment. No production address is hardcoded.
//   VF-PRI-001 .. VF-PRI-006
//     Principal is released only once, only to the release destination bound
//     at creation, only at or after maturity. No early, admin, or oracle path.
//   VF-XCH-024
//     On Base the check is this chain's own lock record. requireLockRecord
//     reverts if that record was never created. No foreign proof is required.
//   VF-XCH-025 / VF-XCH-026 / VF-XCH-034
//     Release does not wait for a foreign Base checker. This contract does
//     not treat an empty block hash or height 0 as finalized, and it does not
//     accept any other header as finalized either.
//   VF-XCH-032
//     The binding payload stored with the lock is exactly 117 bytes:
//     lock id 32, Base recipient 20, output token 1, asset identity 32,
//     valuation reference 32.
//
// VF-SEC-001 (fix 2026-10-23, AG-08): ERC-20 balances are accounted per
// token. owedPrincipal[token] is the principal still owed to open locks of
// that token. A lock is refused while the token balance is below that sum,
// the Dev Fund must receive the fee (a share-rounding allowance of
// FEE_ROUNDING_WEI only), and the fee may not take more than the fee out of
// this contract. A release pays the full principal while the pool covers
// what is owed; after a negative rebase it pays principal * balance / owed,
// so a shortfall is shared pro rata and no lock is paid from another lock's
// principal. A release may not move more than it pays. Positive rebase
// surplus stays in this contract.
//
// Maturity is block.timestamp + duration. The duration gate is an exact
// match against the sixteen COMMITMENT_DURATIONS rows. No range and no
// interpolated multiplier. The one-hour row is the Handshake ($0.01 to
// $0.02). The other fifteen require at least $0.01. All sixteen charge
// 5.00%. Revision 12: no Handshake allowance limit and no per-account
// Handshake counter.
// =============================================================================

// SPDX-License-Identifier: PROTOCOL-RESTRICTED
pragma solidity 0.8.19;

import "./CommitmentDurations.sol";

contract BaseCommitmentVaultLock {
    uint256 public constant STANDARD_FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant HANDSHAKE_DURATION = 1 hours;
    // VF-COM-003: $0.01 to $0.02 inclusive, 18-decimal USD.
    uint256 public constant HANDSHAKE_USD_MIN = 0.01e18;
    uint256 public constant HANDSHAKE_USD_MAX = 0.02e18;
    // VF-COM-009: at least $0.01 for every non-handshake duration.
    uint256 public constant STANDARD_USD_MIN = 0.01e18;

    /// @notice Environment name supplied at deployment. Not a chain id guess.
    string public environmentId;

    /// @notice Dev Fund for this deployment. A deployment input, not a constant.
    address public immutable devFund;

    /// @notice Protocol tokens refused as inputs (VF-TOK-007). Immutable.
    address public immutable vclmToken;
    address public immutable chonxToken;
    address public immutable synthToken;

    struct LockRecord {
        bool exists;
        bool released;
        address creator;
        address releaseDestination;
        address asset; // address(0) means the native asset
        address baseRecipient;
        uint8 outputToken;
        uint256 gross;
        uint256 fee;
        uint256 principal;
        uint256 duration;
        uint256 multiplierBps;
        uint256 createdAt;
        uint256 maturity;
        bytes32 assetIdentity;
        bytes32 valuationReference;
        bytes bindingPayload;
    }

    mapping(bytes32 => LockRecord) private _locks;

    uint256 private _entered;

    /// @notice Principal still owed to open ERC-20 locks, per token (AG-08).
    ///         Appended after _entered so the _locks slot is unchanged.
    mapping(address => uint256) public owedPrincipal;

    /// @notice Share-rounding allowance on the Dev Fund fee receipt (stETH
    ///         style tokens round 1 to 2 wei). A token that keeps more than
    ///         this from the fee is refused.
    uint256 public constant FEE_ROUNDING_WEI = 2;

    event LockCreated(
        bytes32 indexed lockId,
        address indexed creator,
        address indexed releaseDestination,
        address asset,
        uint256 gross,
        uint256 fee,
        uint256 principal,
        uint256 maturity
    );
    event FeeRouted(bytes32 indexed lockId, address indexed devFund, address asset, uint256 fee);
    event PrincipalReleased(bytes32 indexed lockId, address indexed releaseDestination, address asset, uint256 principal);
    event PrincipalReleasedProRata(bytes32 indexed lockId, uint256 principal, uint256 paid, uint256 balance, uint256 owed);

    modifier nonReentrant() {
        require(_entered == 0, "CVL: reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    /// @param environmentId_ Canonical environment name for this deployment.
    /// @param devFund_ Fee destination. Must be supplied. Zero is rejected.
    ///        Absence of a production address is resolved by the deployer of
    ///        this input; this contract does not invent one.
    constructor(string memory environmentId_, address devFund_, address vclm_, address chonx_, address synth_) {
        require(bytes(environmentId_).length != 0, "CVL: environment");
        require(devFund_ != address(0), "CVL: dev fund");
        require(vclm_ != address(0) && chonx_ != address(0) && synth_ != address(0), "CVL: protocol token address");
        environmentId = environmentId_;
        devFund = devFund_;
        vclmToken = vclm_;
        chonxToken = chonx_;
        synthToken = synth_;
    }

    /// @notice True for VCLM, CHONX and SYNTH (VF-TOK-007 / VF-REG-008).
    function isProtocolToken(address token) public view returns (bool) {
        return token == vclmToken || token == chonxToken || token == synthToken;
    }

    function lockRecord(bytes32 lockId) external view returns (LockRecord memory) {
        return _locks[lockId];
    }

    /// @notice Base same-chain check (VF-XCH-024). The record is this chain's
    ///         own storage. An id that was never created is absent.
    function requireLockRecord(bytes32 lockId) external view {
        if (!_locks[lockId].exists) {
            revert("VF-XCH-024: Base lock record absent");
        }
    }

    /// @notice Foreign header finality is not decided here. An empty hash or
    ///         height 0 is not finalized. No other input is finalized either,
    ///         because release waits only on the maturity timestamp.
    ///         Name deliberately does not claim to decide finality.
    function foreignHeaderFinalityNotDecided(bytes32 blockHash, uint256 height) external pure returns (bool) {
        return blockHash != bytes32(0) && height != 0 && false;
    }

    function createNativeLock(
        bytes32 lockId,
        address baseRecipient,
        uint8 outputToken,
        bytes32 assetIdentity,
        bytes32 valuationReference,
        address releaseDestination,
        uint256 duration,
        uint256 verifiedGrossUsd
    ) external payable nonReentrant returns (uint256 fee, uint256 principal) {
        require(msg.value > 0, "CVL: zero gross");
        uint256 multiplierBps;
        (fee, principal, multiplierBps) = _quote(msg.value, duration, verifiedGrossUsd);
        require(fee > 0 && principal > 0, "CVL: zero fee or principal");
        _open(
            lockId,
            baseRecipient,
            outputToken,
            assetIdentity,
            valuationReference,
            releaseDestination,
            duration,
            address(0),
            msg.value,
            fee,
            principal,
            multiplierBps
        );
        (bool ok, ) = devFund.call{value: fee}("");
        require(ok, "CVL: fee");
        emit FeeRouted(lockId, devFund, address(0), fee);
    }

    /// @notice Pulls `amount` of an ERC-20 and accounts the balance delta, not
    ///         the requested amount, as the gross. Fee and principal are taken
    ///         from what this contract actually received.
    function createErc20Lock(
        bytes32 lockId,
        address baseRecipient,
        uint8 outputToken,
        bytes32 assetIdentity,
        bytes32 valuationReference,
        address releaseDestination,
        uint256 duration,
        address token,
        uint256 amount,
        uint256 verifiedGrossUsd
    ) external nonReentrant returns (uint256 fee, uint256 principal) {
        require(token != address(0), "CVL: token");
        // VF-TOK-007 / VF-REG-008: first, before any token moves or fee.
        require(!isProtocolToken(token), "VF-TOK-007: protocol token is not a lock input");
        require(amount > 0, "CVL: zero gross");
        // Reject a stated amount that cannot clear the fee and principal
        // floors before tokens move. The received delta is checked again.
        (uint256 previewFee, uint256 previewPrincipal, ) = _quote(amount, duration, verifiedGrossUsd);
        require(previewFee > 0 && previewPrincipal > 0, "CVL: zero fee or principal");

        uint256 beforeBal = _balanceOf(token, address(this));
        // AG-08: never open a lock into a pool that already cannot cover
        // what it owes, or the new principal would pay older locks.
        require(beforeBal >= owedPrincipal[token], "CVL: token balance below owed principal");
        require(
            _erc20(token, abi.encodeWithSelector(IERC20MinimalBaseLock.transferFrom.selector, msg.sender, address(this), amount)),
            "CVL: transferFrom"
        );
        uint256 received = _balanceOf(token, address(this)) - beforeBal;
        uint256 multiplierBps;
        (fee, principal, multiplierBps) = _quote(received, duration, verifiedGrossUsd);
        require(fee > 0 && principal > 0, "CVL: zero fee or principal");

        _open(
            lockId,
            baseRecipient,
            outputToken,
            assetIdentity,
            valuationReference,
            releaseDestination,
            duration,
            token,
            received,
            fee,
            principal,
            multiplierBps
        );
        _routeErc20Fee(token, fee);
        owedPrincipal[token] += principal;
        emit FeeRouted(lockId, devFund, token, fee);
    }

    /// @notice Releases principal once, to the bound destination, at or after
    ///         maturity. The caller must be that destination. No oracle.
    function release(bytes32 lockId) external nonReentrant {
        LockRecord storage record = _locks[lockId];
        require(record.exists, "CVL: unknown lock");
        require(block.timestamp >= record.maturity, "CVL: immature");
        require(!record.released, "CVL: already released");
        require(msg.sender == record.releaseDestination, "CVL: destination");

        record.released = true;
        uint256 principal = record.principal;
        address asset = record.asset;

        if (asset == address(0)) {
            (bool ok, ) = msg.sender.call{value: principal}("");
            require(ok, "CVL: release");
            emit PrincipalReleased(lockId, msg.sender, asset, principal);
            return;
        }
        uint256 bal = _balanceOf(asset, address(this));
        uint256 owed = owedPrincipal[asset];
        uint256 pay = principal;
        if (bal < owed) {
            // AG-08: the pool is short (negative rebase). Pay this lock's
            // pro-rata share only.
            pay = (principal * bal) / owed;
            emit PrincipalReleasedProRata(lockId, principal, pay, bal, owed);
        }
        owedPrincipal[asset] = owed - principal;
        if (pay != 0) {
            require(
                _erc20(asset, abi.encodeWithSelector(IERC20MinimalBaseLock.transfer.selector, msg.sender, pay)),
                "CVL: release"
            );
            require(bal - _balanceOf(asset, address(this)) <= pay, "CVL: release moved more than paid");
        }
        emit PrincipalReleased(lockId, msg.sender, asset, pay);
    }

    /// @dev AG-08: the fee leaves this contract and reaches the Dev Fund.
    function _routeErc20Fee(address token, uint256 fee) internal {
        uint256 selfBefore = _balanceOf(token, address(this));
        uint256 fundBefore = _balanceOf(token, devFund);
        require(
            _erc20(token, abi.encodeWithSelector(IERC20MinimalBaseLock.transfer.selector, devFund, fee)),
            "CVL: fee"
        );
        require(selfBefore - _balanceOf(token, address(this)) <= fee, "CVL: fee moved more than the fee");
        require(_balanceOf(token, devFund) + FEE_ROUNDING_WEI >= fundBefore + fee, "CVL: Dev Fund fee short");
    }

    function _open(
        bytes32 lockId,
        address baseRecipient,
        uint8 outputToken,
        bytes32 assetIdentity,
        bytes32 valuationReference,
        address releaseDestination,
        uint256 duration,
        address asset,
        uint256 gross,
        uint256 fee,
        uint256 principal,
        uint256 multiplierBps
    ) internal {
        require(baseRecipient != address(0), "CVL: recipient");
        require(releaseDestination != address(0), "CVL: destination");
        require(!_locks[lockId].exists, "CVL: lock exists");

        bytes memory payload = abi.encodePacked(
            lockId,
            baseRecipient,
            outputToken,
            assetIdentity,
            valuationReference
        );
        require(payload.length == 117, "CVL: payload");

        uint256 createdAt = block.timestamp;
        _locks[lockId] = LockRecord({
            exists: true,
            released: false,
            creator: msg.sender,
            releaseDestination: releaseDestination,
            asset: asset,
            baseRecipient: baseRecipient,
            outputToken: outputToken,
            gross: gross,
            fee: fee,
            principal: principal,
            duration: duration,
            multiplierBps: multiplierBps,
            createdAt: createdAt,
            maturity: createdAt + duration,
            assetIdentity: assetIdentity,
            valuationReference: valuationReference,
            bindingPayload: payload
        });

        emit LockCreated(
            lockId,
            msg.sender,
            releaseDestination,
            asset,
            gross,
            fee,
            principal,
            createdAt + duration
        );
    }

    function _quote(uint256 gross, uint256 duration, uint256 verifiedGrossUsd)
        internal
        pure
        returns (uint256 fee, uint256 principal, uint256 multiplierBps)
    {
        multiplierBps = CommitmentDurations.multiplierBps(duration);
        if (multiplierBps == 0) revert("CVL: duration");
        if (duration == HANDSHAKE_DURATION) {
            if (verifiedGrossUsd < HANDSHAKE_USD_MIN || verifiedGrossUsd > HANDSHAKE_USD_MAX) {
                revert("CVL: handshake usd");
            }
        } else {
            if (verifiedGrossUsd < STANDARD_USD_MIN) revert("CVL: standard usd");
        }
        fee = (gross * STANDARD_FEE_BPS) / BPS_DENOMINATOR;
        principal = gross - fee;
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSelector(IERC20MinimalBaseLock.balanceOf.selector, account)
        );
        require(ok && ret.length >= 32, "CVL: balanceOf");
        return abi.decode(ret, (uint256));
    }

    /// @dev Accepts a bare success (no return data) or a single true bool.
    function _erc20(address token, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) return false;
        if (ret.length == 0) return true;
        if (ret.length >= 32) return abi.decode(ret, (bool));
        return false;
    }
}

interface IERC20MinimalBaseLock {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
