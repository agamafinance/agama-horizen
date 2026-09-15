// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IRiskSurface} from "./IRiskSurface.sol";

interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

/// @title CreditDisclosureRegistry
/// @notice An open disclosure primitive for confidential credit books on Horizen.
///
/// Four facts hold here, and they are the whole design:
///
///  1. A position cannot be funded before its terms are committed on-chain. The
///     commitment fixes the payment schedule before anyone knows the outcome.
///  2. Every published aggregate is proven, in zero knowledge, against that
///     commitment. The originator cannot describe a book it did not commit.
///  3. Every revision of the book is itself proven to be an honest evolution of
///     the previous one. A position that has already gone bad cannot be inserted
///     into a clean history with an old origination date.
///  4. Repayments arrive on-chain. Scheduled cash is published in advance;
///     realized cash is observed, not asserted. A clean signature over a bad
///     book therefore survives exactly one payment period.
///
/// The registry does not claim to prove credit quality. It makes credit quality
/// falsifiable in public, on a fixed clock, without naming a single borrower.
contract CreditDisclosureRegistry is IRiskSurface, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @notice Write-down applied to each delinquency bucket, in basis points.
    /// @dev    Public, fixed at deployment, applied mechanically. NAV is a pure
    ///         function of the proven surface and this schedule, so the
    ///         originator has no discretion over its own mark.
    uint16[5] public IMPAIRMENT_BPS = [0, 1000, 3000, 6000, 10000];

    uint64 public constant EPOCH = 30 days;

    IHonkVerifier public immutable verifier;
    IHonkVerifier public immutable deltaVerifier;
    IERC20 public immutable asset;
    uint64 public immutable genesis;

    Surface private _surface;

    /// @notice Block timestamp at which a book root was first committed.
    mapping(bytes32 => uint64) public bookCommittedAt;
    bytes32[] public bookHistory;

    /// @notice The root every future revision must descend from.
    bytes32 public latestRoot;

    /// @notice Valuation date a revision was proven at. Zero for the genesis
    ///         book, which has no predecessor to be valued against.
    mapping(bytes32 => uint64) public bookAsOf;

    /// @notice Cash the book promised for an epoch, written when the epoch opens.
    mapping(uint64 => uint128) public scheduled;
    /// @notice Cash that actually arrived in that epoch.
    mapping(uint64 => uint128) public realized;

    /// @notice Cash the chain has seen leave the vault, cumulatively.
    /// @dev    The hard ceiling on any claimed book. An originator cannot assert
    ///         a position that no disbursement paid for, because disbursement is
    ///         a public transfer and this counter only moves when one happens.
    uint256 public deployedCumulative;

    /// @notice Every stablecoin unit borrowers have returned, cumulatively.
    uint256 public collectedCumulative;
    address public vault;

    /// @notice Independent verification: who looked, when, and what they signed.
    struct Attestation {
        uint64 asOf;
        uint64 at;
        address verifier;
        bytes32 bookRoot;
        bytes32 findingsHash;
    }

    Attestation[] public attestations;

    event BookCommitted(bytes32 indexed bookRoot, uint64 at, uint256 index);
    event RevisionCommitted(bytes32 indexed fromRoot, bytes32 indexed toRoot, uint64 at);
    event SurfacePublished(bytes32 indexed bookRoot, uint64 indexed asOf, uint128 totalPrincipal, uint128 dueNext30d);
    event ScheduleOpened(uint64 indexed epoch, uint128 scheduledAmount);
    event CollectionRecorded(uint64 indexed epoch, uint128 amount, uint128 epochTotal);
    event VerifierAttested(address indexed verifierAddr, uint64 indexed asOf, bytes32 bookRoot, bytes32 findingsHash);
    event DeploymentRecorded(bytes32 indexed bookRoot, uint256 amount, uint256 cumulative);

    error RootNotCommitted();
    error RootAlreadyCommitted();
    error SurfaceNotMonotonic();
    error LeafBackdated();
    error AsOfBeforeCommit();
    error AsOfInFuture();
    error BadProof();
    error WrongPublicInputCount();
    error NoSurface();
    error PrincipalExceedsDisbursed();
    error NotVault();
    error VaultAlreadySet();
    error GenesisAlreadySet();
    error NoGenesisBook();
    error NotDescendedFromLatest();
    error WrongCommitTimestamp();
    error BadDeltaProof();
    error AsOfMismatchesRevision();

    /// @param genesis_ Start of the epoch clock. Explicit rather than
    ///        deployment-time, so the reporting calendar is a stated commitment
    ///        and not an accident of when the contract happened to be mined.
    constructor(
        address verifier_,
        address deltaVerifier_,
        address asset_,
        address admin,
        uint64 genesis_
    ) {
        verifier = IHonkVerifier(verifier_);
        deltaVerifier = IHonkVerifier(deltaVerifier_);
        asset = IERC20(asset_);
        genesis = genesis_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- commit

    /// @notice Commit the first book root. Must happen before the positions it
    ///         covers are funded, and before any surface can be published
    ///         against it. Allowed exactly once: after this, the only way to
    ///         change the book is a proven revision.
    function commitBook(bytes32 bookRoot) external onlyRole(ORIGINATOR_ROLE) {
        if (latestRoot != bytes32(0)) revert GenesisAlreadySet();
        if (bookCommittedAt[bookRoot] != 0) revert RootAlreadyCommitted();
        _commit(bookRoot);
    }

    /// @notice Commit a revision of the book, proven to descend from the current
    ///         root by permitted operations only.
    /// @dev    Public inputs, in circuit order:
    ///           [0] old root, [1] timestamp at which the old root was committed,
    ///           [2] as-of date of the revision, [3] new root.
    ///
    ///         The second input is the load-bearing one. The circuit refuses any
    ///         newly opened position whose origination date precedes it, which is
    ///         what makes inserting an already-defaulted loan into a clean
    ///         history impossible rather than merely expensive.
    function commitRevision(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        onlyRole(ORIGINATOR_ROLE)
    {
        if (publicInputs.length != 4) revert WrongPublicInputCount();
        if (latestRoot == bytes32(0)) revert NoGenesisBook();

        bytes32 fromRoot = publicInputs[0];
        uint64 prevCommitTs = uint64(uint256(publicInputs[1]));
        uint64 asOf = uint64(uint256(publicInputs[2]));
        bytes32 toRoot = publicInputs[3];

        if (fromRoot != latestRoot) revert NotDescendedFromLatest();
        if (prevCommitTs != bookCommittedAt[fromRoot]) revert WrongCommitTimestamp();
        if (asOf > block.timestamp) revert AsOfInFuture();
        if (bookCommittedAt[toRoot] != 0) revert RootAlreadyCommitted();

        if (!deltaVerifier.verify(proof, publicInputs)) revert BadDeltaProof();

        bookAsOf[toRoot] = asOf;
        _commit(toRoot);
        emit RevisionCommitted(fromRoot, toRoot, uint64(block.timestamp));
    }

    function _commit(bytes32 bookRoot) private {
        bookCommittedAt[bookRoot] = uint64(block.timestamp);
        latestRoot = bookRoot;
        bookHistory.push(bookRoot);
        emit BookCommitted(bookRoot, uint64(block.timestamp), bookHistory.length - 1);
    }

    function bookHistoryLength() external view returns (uint256) {
        return bookHistory.length;
    }

    /// @notice Bind the vault whose disbursements cap the claimable book.
    function setVault(address vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
    }

    /// @notice Called by the vault on every disbursement.
    function recordDeployment(bytes32 bookRoot, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        deployedCumulative += amount;
        emit DeploymentRecorded(bookRoot, amount, deployedCumulative);
    }

    // --------------------------------------------------------------- publish

    /// @notice Publish a risk surface proven against a committed book.
    /// @param proof         UltraHonk proof from the book_attest circuit.
    /// @param publicInputs  17 field elements, laid out as the circuit emits them.
    function publishSurface(bytes calldata proof, bytes32[] calldata publicInputs) external {
        if (publicInputs.length != 17) revert WrongPublicInputCount();

        uint64 asOf = uint64(uint256(publicInputs[0]));
        bytes32 bookRoot = publicInputs[1];
        uint64 maxCommittedTs = uint64(uint256(publicInputs[16]));

        uint64 committedAt = bookCommittedAt[bookRoot];
        if (committedAt == 0) revert RootNotCommitted();
        if (asOf > block.timestamp) revert AsOfInFuture();

        uint64 revisionAsOf = bookAsOf[bookRoot];
        if (revisionAsOf == 0) {
            // Genesis book: it must exist on-chain before it can be valued.
            if (asOf < committedAt) revert AsOfBeforeCommit();
        } else {
            // Revision: the surface must be struck at the same date the
            // revision was proven at, so a book cannot be re-proven at a more
            // flattering moment than the one its delta was computed for.
            if (asOf != revisionAsOf) revert AsOfMismatchesRevision();
        }
        if (_surface.asOf != 0 && asOf <= _surface.asOf) revert SurfaceNotMonotonic();

        // Every leaf must claim a commitment no later than the moment this root
        // reached the chain. Without this a defaulted loan could be inserted
        // after the fact and back-dated into a clean history.
        if (maxCommittedTs > committedAt) revert LeafBackdated();

        // A book may never claim more principal than the chain watched leave the
        // vault. This is what stops a backdated leaf from inventing exposure:
        // inventing it costs real, publicly visible cash.
        if (uint256(uint128(uint256(publicInputs[3]))) > deployedCumulative) revert PrincipalExceedsDisbursed();

        if (!verifier.verify(proof, publicInputs)) revert BadProof();

        uint128[5] memory ladder;
        uint128[5] memory delinquent;
        for (uint256 i = 0; i < 5; ++i) {
            ladder[i] = uint128(uint256(publicInputs[4 + i]));
            delinquent[i] = uint128(uint256(publicInputs[10 + i]));
        }

        uint128 dueNext30d = uint128(uint256(publicInputs[9]));

        _surface = Surface({
            bookRoot: bookRoot,
            asOf: asOf,
            positions: uint64(uint256(publicInputs[2])),
            maxCommittedTs: maxCommittedTs,
            totalPrincipal: uint128(uint256(publicInputs[3])),
            dueNext30d: dueNext30d,
            top1: uint128(uint256(publicInputs[15])),
            ladder: ladder,
            delinquent: delinquent
        });

        // The forward calendar becomes a binding public claim for the epoch the
        // surface opens. It is written before the cash is due, never after.
        uint64 e = epochOf(asOf);
        if (scheduled[e] == 0) {
            scheduled[e] = dueNext30d;
            emit ScheduleOpened(e, dueNext30d);
        }

        emit SurfacePublished(bookRoot, asOf, _surface.totalPrincipal, dueNext30d);
    }

    // ------------------------------------------------------------ collection

    /// @notice Pull borrower repayments into the registry and book them against
    ///         the current epoch. Cash is observed on-chain, never asserted.
    function recordCollection(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint64 e = epochOf(uint64(block.timestamp));
        realized[e] += uint128(amount);
        collectedCumulative += amount;
        emit CollectionRecorded(e, uint128(amount), realized[e]);
    }

    /// @notice Forward collected cash to the vault.
    function sweepTo(address to) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        amount = asset.balanceOf(address(this));
        asset.safeTransfer(to, amount);
    }

    // ----------------------------------------------------------- attestation

    /// @notice An independent verifier with full book access records that it
    ///         looked, and what it concluded. The depositor cannot read the
    ///         book; the depositor can read this, and can read its absence.
    function attest(bytes32 bookRoot, uint64 asOf, bytes32 findingsHash) external onlyRole(VERIFIER_ROLE) {
        if (bookCommittedAt[bookRoot] == 0) revert RootNotCommitted();
        attestations.push(
            Attestation({
                asOf: asOf,
                at: uint64(block.timestamp),
                verifier: msg.sender,
                bookRoot: bookRoot,
                findingsHash: findingsHash
            })
        );
        emit VerifierAttested(msg.sender, asOf, bookRoot, findingsHash);
    }

    function attestationCount() external view returns (uint256) {
        return attestations.length;
    }

    /// @notice Seconds since an independent verifier last looked at the book.
    function verificationAge() external view returns (uint256) {
        if (attestations.length == 0) return type(uint256).max;
        return block.timestamp - attestations[attestations.length - 1].at;
    }

    // --------------------------------------------------------------- getters

    function epochOf(uint64 ts) public view returns (uint64) {
        if (ts <= genesis) return 0;
        return (ts - genesis) / EPOCH;
    }

    function currentEpoch() external view returns (uint64) {
        return epochOf(uint64(block.timestamp));
    }

    function surface() external view returns (Surface memory) {
        return _surface;
    }

    function impairedPrincipal() public view returns (uint256 impaired) {
        for (uint256 i = 0; i < 5; ++i) {
            impaired += (uint256(_surface.delinquent[i]) * IMPAIRMENT_BPS[i]) / 10_000;
        }
    }

    /// @notice Principal net of the mechanical write-down. This is the number a
    ///         vault marks against. No one signs it.
    function carryingValue() external view returns (uint256) {
        return uint256(_surface.totalPrincipal) - impairedPrincipal();
    }

    function scheduledFor(uint64 epoch) external view returns (uint128) {
        return scheduled[epoch];
    }

    function realizedFor(uint64 epoch) external view returns (uint128) {
        return realized[epoch];
    }

    function performanceRatio(uint64 epoch) external view returns (uint256) {
        uint128 s = scheduled[epoch];
        if (s == 0) return 0;
        return (uint256(realized[epoch]) * 1e18) / s;
    }

    function attestationAge() external view returns (uint256) {
        if (_surface.asOf == 0) return type(uint256).max;
        return block.timestamp - _surface.asOf;
    }

    function concentration() external view returns (uint256) {
        if (_surface.totalPrincipal == 0) return 0;
        return (uint256(_surface.top1) * 1e18) / _surface.totalPrincipal;
    }

    /// @notice Principal maturing inside the next 30 days. Read by the vault to
    ///         size its own liquidity, so a run is visible before it is a run.
    function nearTermMaturities() external view returns (uint256) {
        return _surface.ladder[0];
    }
}
