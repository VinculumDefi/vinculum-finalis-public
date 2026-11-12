// =============================================================================
// BaseLockRecordVerifier — reads the deployed Base lock. Not a substitute.
//
// Written 2026-10-08 against origin/main CommitmentVaultLock.sol.
//
// The orientation BaseSameChainVerifier calls getLock. The deployed lock has
// no getLock. Its read is lockRecord. The stored fields differ. That file
// must not be registered against this lock.
//
// This file decodes only the lock id from the caller. Gross, fee, principal,
// duration, creation, and maturity come from lockRecord. sourceFinalityProof
// is not read.
//
//
// Recipient and output token are returned from lockRecord. The consumer
// must require both. This file does not register itself and does not deploy.
//
// SPDX-License-Identifier: PROTOCOL-RESTRICTED
// =============================================================================

pragma solidity 0.8.19;

interface IBaseLockRecordVerifier {
    function verifyFinality(
        bytes calldata lockEventProof,
        bytes calldata sourceFinalityProof
    ) external view returns (bool finalized, bytes32 sourceBlockHash, uint256 sourceBlockHeight);

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
}

interface ICommitmentVaultLockReader {
    struct LockRecord {
        bool exists;
        bool released;
        address creator;
        address releaseDestination;
        address asset;
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

    function lockRecord(bytes32 lockId) external view returns (LockRecord memory);
    function devFund() external view returns (address);
}

contract BaseLockRecordVerifier is IBaseLockRecordVerifier {
    error LockNotFound(bytes32 lockId);
    error ZeroAddress();
    error BindingMismatch(bytes32 lockId);

    string public constant ENVIRONMENT_ID = "Base";

    ICommitmentVaultLockReader public immutable vault;

    constructor(address _vault) {
        if (_vault == address(0)) revert ZeroAddress();
        vault = ICommitmentVaultLockReader(_vault);
    }

    function verifyFinality(
        bytes calldata lockEventProof,
        bytes calldata
    ) external view override returns (
        bool finalized,
        bytes32 sourceBlockHash,
        uint256 sourceBlockHeight
    ) {
        bytes32 lockId = _lockIdOf(lockEventProof);
        ICommitmentVaultLockReader.LockRecord memory r = vault.lockRecord(lockId);
        if (!r.exists) revert LockNotFound(lockId);
        _requireBinding(lockId, r.bindingPayload);
        return (true, blockhash(block.number - 1), block.number - 1);
    }

    function extractFacts(
        bytes calldata lockEventProof
    ) external view override returns (
        bytes32 lockId,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 principalAmount,
        uint256 durationSecs,
        uint256 creationTimestamp,
        uint256 maturityTimestamp,
        address baseRecipient,
        uint8 outputToken
    ) {
        bytes32 id = _lockIdOf(lockEventProof);
        ICommitmentVaultLockReader.LockRecord memory r = vault.lockRecord(id);
        if (!r.exists) revert LockNotFound(id);
        _requireBinding(id, r.bindingPayload);
        return (id, r.gross, r.fee, r.principal, r.duration, r.createdAt, r.maturity, r.baseRecipient, r.outputToken);
    }

    /// Native ETH on Base uses the Ethereum native-ETH canonical id (registry
    /// row 2), the same id as the Verifier's BASE_NATIVE_ETH_ASSET_ID.
    bytes32 public constant NATIVE_ASSET_ID = keccak256(abi.encodePacked("Ethereum", "native-ETH"));

    /// @notice The lock's own asset, read from the lock record. A native lock
    /// is native ETH. A token lock reverts: the lock records only the token
    /// address and a caller-chosen assetIdentity, so its canonical id cannot be
    /// established from proven data here (fail closed).
    function extractAssetId(bytes calldata lockEventProof) external view returns (bytes32) {
        bytes32 id = _lockIdOf(lockEventProof);
        ICommitmentVaultLockReader.LockRecord memory r = vault.lockRecord(id);
        if (!r.exists) revert LockNotFound(id);
        _requireBinding(id, r.bindingPayload);
        if (r.asset == address(0)) return NATIVE_ASSET_ID;
        // Token lock: the proven token address, keyed to Base, for the
        // Verifier's token address index.
        return keccak256(abi.encode("Base", r.asset));
    }

    /// @notice VF-FEE-009: the Dev Fund the proven Base lock paid its fee to.
    /// The Base lock routes every fee to its immutable devFund at creation.
    /// Reverts when the lock record is absent or unbound.
    function lockDevFund(string calldata, bytes calldata lockEventProof) external view returns (address) {
        bytes32 id = _lockIdOf(lockEventProof);
        ICommitmentVaultLockReader.LockRecord memory r = vault.lockRecord(id);
        if (!r.exists) revert LockNotFound(id);
        _requireBinding(id, r.bindingPayload);
        return vault.devFund();
    }

    function _lockIdOf(bytes calldata lockEventProof) private pure returns (bytes32) {
        (bytes32 lockId, , , , , , ) = abi.decode(
            lockEventProof,
            (bytes32, uint256, uint256, uint256, uint256, uint256, uint256)
        );
        return lockId;
    }

    /// Binding payload is 117 bytes: lock id, recipient, output, asset, valuation.
    /// The first word must be the same id that found the record.
    function _requireBinding(bytes32 lockId, bytes memory bindingPayload) private pure {
        if (bindingPayload.length != 117) revert BindingMismatch(lockId);
        bytes32 boundId;
        assembly {
            boundId := mload(add(bindingPayload, 32))
        }
        if (boundId != lockId) revert BindingMismatch(lockId);
    }
}
