// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HonkVerifier} from "../src/HonkVerifier.sol";
import {DeltaVerifier} from "../src/DeltaVerifier.sol";
import {CreditDisclosureRegistry} from "../src/CreditDisclosureRegistry.sol";
import {AgamaCreditVault} from "../src/AgamaCreditVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Drives the vault with randomised traffic so the fuzzer can look for
///         an ordering or accounting state the hand-written tests never reach.
contract Handler is Test {
    AgamaCreditVault public vault;
    MockUSDC public usdc;
    address[] public actors;
    uint256[] public openTickets;

    uint256 public depositCount;
    uint256 public requestCount;
    uint256 public settleCount;
    uint256 public cancelCount;

    constructor(AgamaCreditVault v, MockUSDC u) {
        vault = v;
        usdc = u;
        for (uint256 i = 0; i < 6; ++i) {
            address a = address(uint160(0xA11CE000 + i));
            actors.push(a);
            usdc.mint(a, 50_000_000e6);
            vm.prank(a);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1e6, 5_000_000e6);
        if (usdc.balanceOf(a) < amount) return;
        vm.prank(a);
        vault.deposit(amount, a);
        depositCount++;
    }

    function requestRedeem(uint256 seed, uint256 sharesSeed) external {
        address a = _actor(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        if (vault.queueDepth() >= vault.MAX_QUEUE()) return;
        uint256 shares = bound(sharesSeed, 1, bal);
        vm.prank(a);
        uint256 id = vault.requestRedeem(shares);
        openTickets.push(id);
        requestCount++;
    }

    function settle() external {
        if (vault.queueDepth() == 0) return;
        vault.settle();
        settleCount++;
    }

    function cancel(uint256 seed) external {
        if (openTickets.length == 0) return;
        uint256 id = openTickets[seed % openTickets.length];
        AgamaCreditVault.Ticket memory t = vault.ticketAt(id);
        if (t.shares == 0) return;
        vm.prank(t.owner);
        vault.cancelRedeem(id);
        cancelCount++;
    }

    function transferShares(uint256 seedFrom, uint256 seedTo, uint256 amt) external {
        address from = _actor(seedFrom);
        address to = _actor(seedTo);
        uint256 bal = vault.balanceOf(from);
        if (bal == 0 || from == to) return;
        vm.prank(from);
        vault.transfer(to, bound(amt, 1, bal));
    }

    function ticketCount() external view returns (uint256) {
        return openTickets.length;
    }

    function ticketId(uint256 i) external view returns (uint256) {
        return openTickets[i];
    }
}

contract VaultInvariantTest is Test {
    MockUSDC usdc;
    CreditDisclosureRegistry registry;
    AgamaCreditVault vault;
    Handler handler;

    function setUp() public {
        usdc = new MockUSDC();
        HonkVerifier v = new HonkVerifier();
        DeltaVerifier d = new DeltaVerifier();
        registry = new CreditDisclosureRegistry(
            address(v), address(d), address(usdc), address(this), uint64(block.timestamp)
        );
        vault = new AgamaCreditVault(IERC20(address(usdc)), registry, address(this));
        registry.setVault(address(vault));

        handler = new Handler(vault, usdc);
        targetContract(address(handler));
    }

    /// Escrowed shares must equal what the queue says it is holding. If these
    /// drift, someone is owed shares the vault does not have.
    function invariant_EscrowMatchesQueue() public view {
        assertEq(vault.balanceOf(address(vault)), vault.queuedShares(), "escrow drift");
    }

    /// The queue total must equal the sum of the open tickets, one by one.
    function invariant_QueueTotalMatchesTickets() public view {
        uint256 sum;
        uint256 n = handler.ticketCount();
        for (uint256 i = 0; i < n; ++i) {
            sum += vault.ticketAt(handler.ticketId(i)).shares;
        }
        assertEq(sum, vault.queuedShares(), "ticket sum drift");
    }

    /// Queued shares can never exceed the shares in existence.
    function invariant_QueueWithinSupply() public view {
        assertLe(vault.queuedShares(), vault.totalSupply(), "queue exceeds supply");
    }

    /// First-loss capital is escrowed, so the vault can never hold less than it.
    function invariant_FirstLossStaysCovered() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.firstLoss(), "first loss spent");
    }

    /// No redemption may pay out more than the vault is worth.
    function invariant_NoValueCreation() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + 1, "value created");
    }

    function invariant_CallSummary() public view {
        console.log("deposits ", handler.depositCount());
        console.log("requests ", handler.requestCount());
        console.log("settles  ", handler.settleCount());
        console.log("cancels  ", handler.cancelCount());
    }
}
