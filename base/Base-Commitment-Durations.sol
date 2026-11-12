// =============================================================================
// CommitmentDurations — the sixteen Commitment Vault Lock rows.
//
// Source: src/lib/vfRevision6Authority.js COMMITMENT_DURATIONS.
// Exact seconds and multiplier_bps. No range. No interpolation.
// =============================================================================

// SPDX-License-Identifier: PROTOCOL-RESTRICTED
pragma solidity 0.8.19;

library CommitmentDurations {
    uint256 internal constant COUNT = 16;

    /// @dev Returns the row's multiplier in basis points, or 0 if secs is not
    ///      one of the sixteen exact durations.
    function multiplierBps(uint256 secs) internal pure returns (uint256) {
        if (secs == 3600) return 10000; // 1 hour
        if (secs == 604800) return 10000; // 7 days
        if (secs == 2592000) return 11500; // 30 days
        if (secs == 5184000) return 13000; // 60 days
        if (secs == 7776000) return 15000; // 90 days
        if (secs == 15552000) return 20000; // 180 days
        if (secs == 31536000) return 25000; // 365 days
        if (secs == 63072000) return 38000; // 730 days
        if (secs == 94608000) return 50000; // 1,095 days
        if (secs == 126144000) return 57500; // 1,460 days
        if (secs == 157680000) return 65000; // 1,825 days
        if (secs == 189216000) return 68000; // 2,190 days
        if (secs == 220752000) return 71000; // 2,555 days
        if (secs == 252288000) return 74000; // 2,920 days
        if (secs == 283824000) return 77000; // 3,285 days
        if (secs == 315360000) return 80000; // 3,650 days
        return 0;
    }
}
