// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {CreditDisclosureRegistry} from "./CreditDisclosureRegistry.sol";

interface IPureFiVerifier {
    function validatePayload(bytes calldata purefiData) external;
}

/// @title AgamaCreditVault
/// @notice An ERC-4626 private credit vault whose book is confidential and whose
///         risk, liquidity and exit queue are not.
///
/// Two properties answer the two hard questions about confidential credit:
///
///  - NAV is computed, never asserted. It is a pure function of the proven risk
///    surface and a public impairment schedule, so the originator cannot mark
///    its own book.
///  - The exit queue is public state and settles strictly pro-rata. There is no
///    first-mover advantage, therefore no reason to run, and no depositor is
///    ever last to learn that others are leaving.
contract AgamaCreditVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");

    /// @dev Bounded so settlement always fits in one block. Exceeding it is a
    ///      public condition, not a discretionary gate.
    uint256 public constant MAX_QUEUE = 256;

    CreditDisclosureRegistry public immutable registry;

    /// @notice Originator first-loss capital, escrowed here, junior to depositors.
    uint256 public firstLoss;

    /// @notice Minimum share of the book that must stay in liquid stablecoins,
    ///         in basis points.
    /// @dev    Expressed as a share rather than a fixed sum on purpose. A fixed
    ///         buffer is most of a small vault and a rounding error in a large
    ///         one, and it is the ratio of cash to obligations that decides
    ///         whether a redemption can be paid. A share scales with the book it
    ///         protects instead of being re-tuned by hand after every raise.
    uint16 public floorBps;

    /// @notice Principal the vault has written off. Counted into the floor base
    ///         because a write-down lowers recorded exposure with no cash
    ///         moving, and a base the originator can lower is not a floor.
    uint256 public writtenOff;

    IPureFiVerifier public compliance;

    struct Ticket {
        address owner;
        uint128 shares;
        uint64 requestedAt;
    }

    Ticket[] private _queue;
    uint256 public head;
    uint256 public queuedShares;

    event RedemptionRequested(address indexed owner, uint256 indexed ticketId, uint256 shares, uint256 queueDepth);
    event RedemptionSettled(uint256 indexed ticketId, address indexed owner, uint256 shares, uint256 assets);
    event SettlementRound(uint256 ratio, uint256 ticketsTouched, uint256 assetsPaid);
    event FirstLossPosted(address indexed from, uint256 amount, uint256 total);
    event Deployed(address indexed to, uint256 amount, bytes32 bookRoot);
    event FloorUpdated(uint16 oldBps, uint16 newBps);

    error QueueFull();
    error NothingQueued();
    error NotTicketOwner();
    error BookNotCommitted();
    error UndercollateralisedDeployment();
    error BreachesReserveFloor(uint256 wouldLeave, uint256 required);
    error FloorTooHigh();

    constructor(IERC20 asset_, CreditDisclosureRegistry registry_, address admin)
        ERC4626(asset_)
        ERC20("Agama Private Credit", "agPC")
    {
        registry = registry_;
        floorBps = 1000; // 10 percent
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFloorBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert FloorTooHigh();
        emit FloorUpdated(floorBps, bps);
        floorBps = bps;
    }

    /// @notice Liquid stablecoins the vault may not go below, in asset units.
    function reserveFloor() public view returns (uint256) {
        uint256 base = buffer() + registry.surface().totalPrincipal + writtenOff;
        return (base * floorBps) / 10_000;
    }

    // ------------------------------------------------------------------- NAV

    /// @notice Liquid stablecoins held by the vault, excluding first-loss escrow.
    function buffer() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - firstLoss;
    }

    /// @inheritdoc ERC4626
    /// @dev NAV = liquid buffer + principal outstanding - mechanical impairment
    ///      + whatever the originator's first-loss absorbs of that impairment.
    ///      Every term is either an on-chain balance or a proven public input.
    function totalAssets() public view override returns (uint256) {
        uint256 principal = registry.surface().totalPrincipal;
        uint256 impaired = registry.impairedPrincipal();
        uint256 absorbed = impaired < firstLoss ? impaired : firstLoss;
        return buffer() + principal - impaired + absorbed;
    }

    /// @notice First-loss capital not yet consumed by impairment. Watching this
    ///         fall is how a depositor sees credit deteriorate before it reaches
    ///         them, without seeing a single borrower.
    function firstLossRemaining() public view returns (uint256) {
        uint256 impaired = registry.impairedPrincipal();
        return impaired >= firstLoss ? 0 : firstLoss - impaired;
    }

    /// @notice Fraction of outstanding principal covered by first-loss, 1e18 scale.
    function firstLossCoverage() external view returns (uint256) {
        uint256 principal = registry.surface().totalPrincipal;
        if (principal == 0) return type(uint256).max;
        return (firstLoss * 1e18) / principal;
    }

    // ----------------------------------------------------------- originator

    function postFirstLoss(uint256 amount) external onlyRole(ORIGINATOR_ROLE) nonReentrant {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        firstLoss += amount;
        emit FirstLossPosted(msg.sender, amount, firstLoss);
    }

    /// @notice Disburse against a book root that is already committed.
    /// @dev    The ordering is the point: terms are committed before cash moves,
    ///         so the schedule a position will be judged against cannot be
    ///         written after its outcome is known.
    function deploy(address to, uint256 amount, bytes32 bookRoot)
        external
        onlyRole(ORIGINATOR_ROLE)
        nonReentrant
    {
        if (registry.bookCommittedAt(bookRoot) == 0) revert BookNotCommitted();
        uint256 free = buffer();
        if (amount > free) revert UndercollateralisedDeployment();

        // The floor is measured on the book this deployment creates, not the
        // one that existed before it, so it cannot be dodged by ordering.
        uint256 left = free - amount;
        uint256 required = ((left + registry.surface().totalPrincipal + amount + writtenOff) * floorBps) / 10_000;
        if (left < required) revert BreachesReserveFloor(left, required);

        IERC20(asset()).safeTransfer(to, amount);
        registry.recordDeployment(bookRoot, amount);
        emit Deployed(to, amount, bookRoot);
    }

    // ------------------------------------------------------------ compliance

    function setCompliance(address verifier_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IPureFiVerifier(verifier_);
    }

    /// @notice Deposit behind a synchronous AML check. Reverts as one transaction
    ///         if the check fails, so a non-compliant deposit never exists.
    function depositWithCompliance(uint256 assets, address receiver, bytes calldata purefiData)
        external
        returns (uint256)
    {
        if (address(compliance) != address(0)) compliance.validatePayload(purefiData);
        return deposit(assets, receiver);
    }

    // ----------------------------------------------------------- exit queue

    /// @dev Instant redemption is disabled by design: an instant exit for the
    ///      fastest depositor is the mechanism that turns illiquidity into a run.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Join the public exit queue. The request, its size and its place
    ///         are on-chain the moment it is made.
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 ticketId) {
        if (_queue.length - head >= MAX_QUEUE) revert QueueFull();
        _transfer(msg.sender, address(this), shares);
        ticketId = _queue.length;
        _queue.push(Ticket({owner: msg.sender, shares: uint128(shares), requestedAt: uint64(block.timestamp)}));
        queuedShares += shares;
        emit RedemptionRequested(msg.sender, ticketId, shares, _queue.length - head);
    }

    /// @notice Settle the whole open queue at one ratio for everyone.
    /// @dev    Permissionless. Nobody chooses who gets paid, and the ratio is
    ///         identical for the first ticket and the last, so queuing early
    ///         buys nothing.
    function settle() external nonReentrant returns (uint256 ratio) {
        uint256 open = _queue.length - head;
        if (open == 0) revert NothingQueued();

        uint256 owed = convertToAssets(queuedShares);
        uint256 avail = buffer();
        ratio = owed == 0 ? 0 : (avail >= owed ? 1e18 : (avail * 1e18) / owed);

        uint256 paid;
        uint256 i = head;
        uint256 end = _queue.length;
        for (; i < end; ++i) {
            Ticket storage t = _queue[i];
            uint256 payShares = (uint256(t.shares) * ratio) / 1e18;
            if (payShares == 0) continue;
            uint256 assets = convertToAssets(payShares);

            t.shares -= uint128(payShares);
            queuedShares -= payShares;
            _burn(address(this), payShares);
            IERC20(asset()).safeTransfer(t.owner, assets);
            paid += assets;

            emit RedemptionSettled(i, t.owner, payShares, assets);
        }

        while (head < _queue.length && _queue[head].shares == 0) {
            ++head;
        }

        emit SettlementRound(ratio, end - head, paid);
    }

    /// @notice Withdraw a still-unsettled request and take the shares back.
    function cancelRedeem(uint256 ticketId) external nonReentrant {
        Ticket storage t = _queue[ticketId];
        if (t.owner != msg.sender) revert NotTicketOwner();
        uint256 shares = t.shares;
        t.shares = 0;
        queuedShares -= shares;
        _transfer(address(this), msg.sender, shares);
    }

    // -------------------------------------------------------- public signals

    function queueDepth() external view returns (uint256) {
        return _queue.length - head;
    }

    function queuedAssets() external view returns (uint256) {
        return convertToAssets(queuedShares);
    }

    function ticketAt(uint256 i) external view returns (Ticket memory) {
        return _queue[i];
    }

    /// @notice Cash reachable within 30 days against cash demanded by the queue,
    ///         1e18 scale. Below 1e18 the vault is telling depositors it cannot
    ///         pay everyone next month, a month before it has to.
    function coverageRatio() external view returns (uint256) {
        uint256 owed = convertToAssets(queuedShares);
        if (owed == 0) return type(uint256).max;
        CreditDisclosureRegistry.Surface memory s = registry.surface();
        uint256 reachable = buffer() + s.dueNext30d + s.ladder[0];
        return (reachable * 1e18) / owed;
    }
}
