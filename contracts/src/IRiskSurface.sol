// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRiskSurface
/// @notice Machine-readable credit disclosure for a confidential loan book.
/// @dev    The point of this interface is that a *contract* can underwrite a
///         confidential vault, not only a human reading a PDF. A Horizen money
///         market can set an LTV on vault shares by calling these getters.
///         Nothing here reveals a borrower. Everything here reveals risk.
interface IRiskSurface {
    /// @param bookRoot        Merkle commitment to the private loan book.
    /// @param asOf            Valuation timestamp the aggregates are measured at.
    /// @param positions       Number of active positions.
    /// @param maxCommittedTs  Newest per-leaf commitment timestamp in the book.
    /// @param totalPrincipal  Outstanding principal, asset decimals.
    /// @param dueNext30d      Contractual cash due over the 30 days after asOf.
    /// @param top1            Largest single-obligor exposure.
    /// @param ladder          Principal maturing in <=30d, <=90d, <=180d, <=365d, >365d.
    /// @param delinquent      Principal by bucket: current, 1-30, 31-60, 61-90, 90+.
    struct Surface {
        bytes32 bookRoot;
        uint64 asOf;
        uint64 positions;
        uint64 maxCommittedTs;
        uint128 totalPrincipal;
        uint128 dueNext30d;
        uint128 top1;
        uint128[5] ladder;
        uint128[5] delinquent;
    }

    /// @notice The latest proven risk surface.
    function surface() external view returns (Surface memory);

    /// @notice Principal written down by the public impairment schedule, in asset decimals.
    function impairedPrincipal() external view returns (uint256);

    /// @notice Cash the book promised, in public, before the period began.
    function scheduledFor(uint64 epoch) external view returns (uint128);

    /// @notice Cash that actually landed on-chain in that period.
    function realizedFor(uint64 epoch) external view returns (uint128);

    /// @notice realized / scheduled for a closed epoch, 1e18 scale. The series
    ///         that makes a signed-but-bad book fail in public within one period.
    function performanceRatio(uint64 epoch) external view returns (uint256);

    /// @notice Seconds since the last proven surface. Stale disclosure is itself a signal.
    function attestationAge() external view returns (uint256);

    /// @notice Concentration as a fraction of outstanding principal, 1e18 scale.
    function concentration() external view returns (uint256);
}
