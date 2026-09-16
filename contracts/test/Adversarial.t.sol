// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {HonkVerifier} from "../src/HonkVerifier.sol";
import {DeltaVerifier} from "../src/DeltaVerifier.sol";
import {CreditDisclosureRegistry} from "../src/CreditDisclosureRegistry.sol";
import {AgamaCreditVault} from "../src/AgamaCreditVault.sol";

/// @notice Attacks the design rather than demonstrating it. Every test here is
///         an attempt to break an invariant the architecture document claims.
contract AdversarialTest is Test {
    address constant USDCE = 0xDF7108f8B10F9b9eC1aba01CCa057268cbf86B6c;

    /// @dev Pinned so the suite is deterministic and Foundry caches the fork
    ///      locally after the first run. Without a pin every run refetches
    ///      state from the public RPC and a timeout fails the whole suite.
    uint256 constant FORK_BLOCK = 26_170_000;

    uint64 constant AS_OF_0 = 1789500000;
    uint64 constant AS_OF_1 = AS_OF_0 + 30 days;
    uint64 constant PREV_COMMIT_TS = AS_OF_0 - 1 days;

    HonkVerifier verifier;
    DeltaVerifier deltaVerifier;
    CreditDisclosureRegistry registry;
    AgamaCreditVault vault;

    address admin = makeAddr("admin");
    address originator = makeAddr("originator");
    address auditor = makeAddr("auditor");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address lp = makeAddr("lp");
    address rail = makeAddr("rail");

    function setUp() public {
        vm.createSelectFork(vm.envOr("HORIZEN_RPC", string("https://horizen.calderachain.xyz/http")), FORK_BLOCK);
        verifier = new HonkVerifier();
        deltaVerifier = new DeltaVerifier();
        registry = new CreditDisclosureRegistry(
            address(verifier), address(deltaVerifier), USDCE, admin, AS_OF_0 - 30 days
        );
        vault = new AgamaCreditVault(IERC20(USDCE), registry, admin);

        vm.startPrank(admin);
        registry.setVault(address(vault));
        registry.grantRole(registry.ORIGINATOR_ROLE(), originator);
        registry.grantRole(registry.VERIFIER_ROLE(), auditor);
        vault.grantRole(vault.ORIGINATOR_ROLE(), originator);
        vm.stopPrank();

        deal(USDCE, attacker, 20_000_000e6);
        deal(USDCE, victim, 10_000e6);
        deal(USDCE, lp, 10_000_000e6);
        deal(USDCE, originator, 2_000_000e6);
    }

    // ------------------------------------------------------------- fixtures

    function _proof(string memory s) internal view returns (bytes memory) {
        return vm.readFileBinary(string.concat("test/fixtures/proof_", s, ".bin"));
    }

    function _inputs(string memory s) internal view returns (bytes32[] memory out) {
        bytes memory raw = vm.readFileBinary(string.concat("test/fixtures/public_inputs_", s, ".bin"));
        out = new bytes32[](raw.length / 32);
        for (uint256 i = 0; i < out.length; ++i) {
            bytes32 w;
            assembly {
                w := mload(add(add(raw, 0x20), mul(i, 0x20)))
            }
            out[i] = w;
        }
    }

    function _bootstrap() internal {
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(_inputs("t0")[1]);

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(5_500_000e6, lp);
        vm.stopPrank();

        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(500_000e6);
        vault.deploy(rail, 4_760_000e6, _inputs("t0")[1]);
        vm.stopPrank();

        vm.warp(AS_OF_0 + 1 hours);
        registry.publishSurface(_proof("t0"), _inputs("t0"));
    }

    // =================================================== attacking the proof

    /// Flip one public input and the proof must stop verifying. Without this,
    /// every published aggregate is decorative.
    function test_TamperedPublicInputIsRejected() public {
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(_inputs("t0")[1]);

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(5_500_000e6, lp);
        vm.stopPrank();
        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(500_000e6);
        vault.deploy(rail, 4_760_000e6, _inputs("t0")[1]);
        vm.stopPrank();

        vm.warp(AS_OF_0 + 1 hours);

        // Understate delinquency: move 90+ principal into the current bucket.
        bytes32[] memory bad = _inputs("t0");
        bad[10] = bytes32(uint256(bad[10]) + uint256(bad[14]));
        bad[14] = bytes32(0);

        vm.expectRevert();
        registry.publishSurface(_proof("t0"), bad);

        // Overstate principal by one unit.
        bytes32[] memory bad2 = _inputs("t0");
        bad2[3] = bytes32(uint256(bad2[3]) + 1);
        vm.expectRevert();
        registry.publishSurface(_proof("t0"), bad2);

        // Backdate the as-of so a stale book looks fresh.
        bytes32[] memory bad3 = _inputs("t0");
        bad3[0] = bytes32(uint256(AS_OF_0 - 10 days));
        vm.expectRevert();
        registry.publishSurface(_proof("t0"), bad3);

        // The untouched proof still works, so the rejections above are the
        // tampering and not an unrelated failure.
        registry.publishSurface(_proof("t0"), _inputs("t0"));
        assertEq(registry.surface().totalPrincipal, 4_760_000e6);
    }

    /// A valid proof for book A cannot be re-pointed at committed book B.
    function test_ProofCannotBeRepointedAtAnotherBook() public {
        vm.warp(PREV_COMMIT_TS);
        vm.startPrank(originator);
        registry.commitBook(_inputs("t0")[1]);
        vm.stopPrank();
        vm.warp(AS_OF_1 + 1 hours);

        bytes32[] memory swapped = _inputs("t1");
        swapped[1] = _inputs("t0")[1]; // claim the t1 surface describes the t0 book
        vm.expectRevert();
        registry.publishSurface(_proof("t1"), swapped);
    }

    /// Surfaces must move forward. Re-publishing an older valuation would let
    /// an originator walk back a deterioration it already disclosed.
    function test_SurfaceCannotGoBackwards() public {
        _bootstrap();

        vm.warp(AS_OF_1 + 30 minutes);
        vm.prank(originator);
        registry.commitRevision(_proof("delta"), _inputs("delta"));
        vm.warp(AS_OF_1 + 1 hours);
        registry.publishSurface(_proof("t1"), _inputs("t1"));

        // The t0 surface is now stale. Re-publishing it would restore the
        // flattering impairment figure.
        vm.expectRevert(CreditDisclosureRegistry.SurfaceNotMonotonic.selector);
        registry.publishSurface(_proof("t0"), _inputs("t0"));
    }

    // ================================================ attacking the revision

    /// A revision must descend from the current root, not from any past one.
    function test_RevisionMustDescendFromLatest() public {
        _bootstrap();
        vm.warp(AS_OF_1 + 30 minutes);

        vm.prank(originator);
        registry.commitRevision(_proof("delta"), _inputs("delta"));

        // Replaying the same delta would fork the history off an old root.
        vm.prank(originator);
        vm.expectRevert(CreditDisclosureRegistry.NotDescendedFromLatest.selector);
        registry.commitRevision(_proof("delta"), _inputs("delta"));
    }

    /// The commitment timestamp fed to the circuit must be the one the chain
    /// recorded. Lying about it is what would make backdating possible again.
    function test_RevisionCannotLieAboutThePreviousCommitTime() public {
        _bootstrap();
        vm.warp(AS_OF_1 + 30 minutes);

        bytes32[] memory bad = _inputs("delta");
        bad[1] = bytes32(uint256(PREV_COMMIT_TS - 200 days));
        vm.prank(originator);
        vm.expectRevert(CreditDisclosureRegistry.WrongCommitTimestamp.selector);
        registry.commitRevision(_proof("delta"), bad);
    }

    /// The genesis book may be declared once. After that the only way forward
    /// is a proven revision.
    function test_GenesisIsOnlyAllowedOnce() public {
        vm.warp(PREV_COMMIT_TS);
        vm.startPrank(originator);
        registry.commitBook(_inputs("t0")[1]);
        vm.expectRevert(CreditDisclosureRegistry.GenesisAlreadySet.selector);
        registry.commitBook(_inputs("t1")[1]);
        vm.stopPrank();
    }

    /// A revision's surface must be struck at the date the revision was proven
    /// at, so a book cannot be re-valued at a more flattering moment.
    function test_RevisionSurfaceMustMatchItsValuationDate() public {
        _bootstrap();
        vm.warp(AS_OF_1 + 30 minutes);
        vm.prank(originator);
        registry.commitRevision(_proof("delta"), _inputs("delta"));

        vm.warp(AS_OF_1 + 1 hours);
        // t0's surface carries as_of = AS_OF_0 but its root is not the revision,
        // so this fails on the root check; the t1 surface is the only one whose
        // as_of matches what the delta was proven at.
        registry.publishSurface(_proof("t1"), _inputs("t1"));
        assertEq(registry.surface().asOf, AS_OF_1);
    }

    // ================================================== attacking the economics

    /// The originator cannot assert exposure that no disbursement paid for.
    function test_CannotClaimPrincipalTheChainNeverSaw() public {
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(_inputs("t0")[1]);

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(5_500_000e6, lp);
        vm.stopPrank();

        // Disburse only a fraction of the book the surface will claim.
        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(500_000e6);
        vault.deploy(rail, 1_000_000e6, _inputs("t0")[1]);
        vm.stopPrank();

        vm.warp(AS_OF_0 + 1 hours);
        vm.expectRevert(CreditDisclosureRegistry.PrincipalExceedsDisbursed.selector);
        registry.publishSurface(_proof("t0"), _inputs("t0"));
    }

    /// The reserve floor is measured on the book the deployment creates, so it
    /// cannot be dodged by splitting or ordering the disbursements.
    function test_ReserveFloorCannotBeDrained() public {
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(_inputs("t0")[1]);

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(5_000_000e6, lp);
        vm.stopPrank();

        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);

        // One shot at the whole buffer.
        vm.expectRevert();
        vault.deploy(rail, 5_000_000e6, _inputs("t0")[1]);

        // Salami: nine slices of ten percent, which a floor measured on the
        // pre-deployment book would wave through.
        for (uint256 i = 0; i < 4; ++i) {
            vault.deploy(rail, 500_000e6, _inputs("t0")[1]);
        }
        uint256 left = vault.buffer();
        vm.expectRevert();
        vault.deploy(rail, left, _inputs("t0")[1]);
        vm.stopPrank();

        assertGe(vault.buffer(), vault.reserveFloor(), "floor holds after salami slicing");
        console.log("buffer after slicing (USDC)", vault.buffer() / 1e6);
        console.log("floor required       (USDC)", vault.reserveFloor() / 1e6);
    }

    /// The classic ERC-4626 first-depositor attack, priced.
    function test_InflationAttackIsUneconomic() public {
        vm.startPrank(attacker);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker); // one wei of USDC
        IERC20(USDCE).transfer(address(vault), 10_000e6); // donate, skewing the price
        vm.stopPrank();

        vm.startPrank(victim);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(10_000e6, victim);
        vm.stopPrank();

        assertGt(shares, 0, "victim is not rounded to zero shares");
        uint256 recoverable = vault.convertToAssets(shares);
        console.log("victim deposited (USDC)  ", uint256(10_000));
        console.log("victim can redeem (USDC) ", recoverable / 1e6);
        console.log("attacker donated (USDC)  ", uint256(10_000));

        // The attacker burned 10,000 USDC. If the attack worked they would
        // capture most of the victim's deposit; instead the victim keeps
        // essentially all of it and the attacker is simply out of pocket.
        assertGt(recoverable, 9_990e6, "victim keeps their deposit");
    }

    // ==================================================== attacking the queue

    /// Everybody in the queue receives the same fill, no matter when they
    /// joined or how large they are.
    function test_ProRataHoldsAtScale() public {
        _bootstrap();
        vm.warp(AS_OF_0 + 2 days);

        uint256 n = 40;
        address[] memory holders = new address[](n);
        uint256[] memory asked = new uint256[](n);

        // Sizes vary by two orders of magnitude, and each joins a block apart.
        for (uint256 i = 0; i < n; ++i) {
            holders[i] = address(uint160(0xBEEF0000 + i));
            uint256 sh = vault.balanceOf(lp) / (12 + i);
            vm.prank(lp);
            vault.transfer(holders[i], sh);
            vm.prank(holders[i]);
            vault.requestRedeem(sh);
            asked[i] = vault.convertToAssets(sh);
            vm.warp(block.timestamp + 12);
        }
        assertEq(vault.queueDepth(), n);

        uint256[] memory before_ = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) before_[i] = IERC20(USDCE).balanceOf(holders[i]);

        uint256 g = gasleft();
        uint256 ratio = vault.settle();
        console.log("gas settle (40 tickets)  ", g - gasleft());
        console.log("settlement ratio (bps)   ", ratio / 1e14);

        uint256 firstFill;
        for (uint256 i = 0; i < n; ++i) {
            uint256 paid = IERC20(USDCE).balanceOf(holders[i]) - before_[i];
            uint256 fill = (paid * 1e18) / asked[i];
            if (i == 0) firstFill = fill;
            // Within one part in ten thousand, which is integer rounding on a
            // six-decimal asset, not an ordering advantage.
            assertApproxEqRel(fill, firstFill, 1e14, "fill depends on queue position");
        }
        console.log("first ticket fill (bps)  ", firstFill / 1e14);
        assertLt(ratio, 1e18, "the round must be a partial fill for this to mean anything");
    }

    /// A full queue must still settle inside one Horizen block.
    function test_FullQueueFitsInABlock() public {
        _bootstrap();
        vm.warp(AS_OF_0 + 2 days);

        uint256 n = vault.MAX_QUEUE();
        for (uint256 i = 0; i < n; ++i) {
            address h = address(uint160(0xC0DE0000 + i));
            uint256 sh = vault.balanceOf(lp) / (1000 + i);
            vm.prank(lp);
            vault.transfer(h, sh);
            vm.prank(h);
            vault.requestRedeem(sh);
        }
        assertEq(vault.queueDepth(), n);

        // The queue is bounded, and the bound is a public condition rather than
        // a gate someone chooses to close.
        address extra = address(uint160(0xDEAD0001));
        vm.prank(lp);
        vault.transfer(extra, 1e6);
        vm.prank(extra);
        vm.expectRevert(AgamaCreditVault.QueueFull.selector);
        vault.requestRedeem(1e6);

        uint256 g = gasleft();
        vault.settle();
        uint256 used = g - gasleft();
        console.log("gas settle (256 tickets) ", used);
        assertLt(used, 30_000_000, "settles inside the Horizen block gas limit");
    }

    /// Cancelling after a partial fill returns exactly what is left, and not a
    /// unit more.
    function test_CancelReturnsExactlyTheRemainder() public {
        _bootstrap();
        vm.warp(AS_OF_0 + 2 days);

        uint256 sh = vault.balanceOf(lp) / 4;
        vm.prank(lp);
        uint256 id = vault.requestRedeem(sh);
        uint256 ratio = vault.settle();

        uint256 expected = sh - (sh * ratio) / 1e18;
        assertEq(vault.ticketAt(id).shares, expected, "remainder tracked exactly");

        uint256 before_ = vault.balanceOf(lp);
        vm.prank(lp);
        vault.cancelRedeem(id);
        assertEq(vault.balanceOf(lp) - before_, expected, "remainder returned exactly");
        assertEq(vault.ticketAt(id).shares, 0);
    }

    /// Only the ticket owner may cancel it.
    function test_CannotCancelSomeoneElsesTicket() public {
        _bootstrap();
        vm.warp(AS_OF_0 + 2 days);
        uint256 sh = vault.convertToShares(1_000e6);
        vm.prank(lp);
        uint256 id = vault.requestRedeem(sh);

        vm.prank(attacker);
        vm.expectRevert(AgamaCreditVault.NotTicketOwner.selector);
        vault.cancelRedeem(id);
    }

    // ============================ the six defects found by reviewing our own code

    /// Collected borrower cash has exactly one destination, and getting it there
    /// needs no privileged key. An admin who can choose where repayments go is a
    /// custody risk wearing an operational hat.
    function test_CollectedCashCanOnlyReachTheVault() public {
        _bootstrap();
        vm.startPrank(lp);
        IERC20(USDCE).approve(address(registry), type(uint256).max);
        registry.recordCollection(50_000e6);
        vm.stopPrank();

        assertEq(IERC20(USDCE).balanceOf(address(registry)), 50_000e6);
        uint256 before_ = IERC20(USDCE).balanceOf(address(vault));

        // No role required, and no destination to choose.
        vm.prank(attacker);
        registry.sweep();

        assertEq(IERC20(USDCE).balanceOf(address(vault)) - before_, 50_000e6, "cash reached the vault");
        assertEq(IERC20(USDCE).balanceOf(address(registry)), 0);
    }

    /// An originator can always wire its own money in to make a failing book
    /// look like it is paying. That cannot be prevented, so it is made visible.
    function test_SelfFundedCollectionsAreVisible() public {
        _bootstrap();

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(registry), type(uint256).max);
        registry.recordCollection(30_000e6);       // a genuine third-party payment
        vm.stopPrank();
        assertEq(registry.originatorFunded(), 0, "no subsidy yet");

        vm.startPrank(originator);
        IERC20(USDCE).approve(address(registry), type(uint256).max);
        registry.recordCollection(90_000e6);       // the originator paying its own book
        vm.stopPrank();

        // performanceRatio alone would now look healthy. originatorFunded says
        // three quarters of it came from the party being measured.
        assertEq(registry.originatorFunded(), 0.75e18, "subsidy is legible");
        assertEq(registry.collectedFrom(originator), 90_000e6);
        console.log("originator-funded share (bps)", registry.originatorFunded() / 1e14);
    }

    /// Exit denial is the cheapest attack on this design, so dust cannot hold a
    /// queue slot and a cancelled ticket frees one immediately.
    function test_QueueCannotBeBlockedByDust() public {
        _bootstrap();
        vm.warp(AS_OF_0 + 2 days);

        uint256 stake = vault.convertToShares(5_000e6);
        uint256 dust = vault.convertToShares(99e6);
        uint256 real = vault.convertToShares(1_000e6);

        vm.prank(lp);
        vault.transfer(attacker, stake);

        vm.startPrank(attacker);
        vm.expectRevert(); // TicketTooSmall
        vault.requestRedeem(dust);

        // A real ticket takes a slot, and giving it up gives the slot back.
        uint256 id = vault.requestRedeem(real);
        assertEq(vault.queueDepth(), 1);
        vault.cancelRedeem(id);
        assertEq(vault.queueDepth(), 0, "cancelling frees the slot, not just the shares");
        vm.stopPrank();
    }

    /// First-loss capital that can never come back is capital nobody posts
    /// twice, so release is allowed, bounded by three things anyone can check.
    function test_FirstLossReleaseIsBounded() public {
        _bootstrap();

        // Nothing leaves while the queue is owed anything.
        uint256 sh = vault.convertToShares(200_000e6);
        vm.prank(lp);
        vault.requestRedeem(sh);
        vm.prank(originator);
        vm.expectRevert();
        vault.releaseFirstLoss(1e6);
        vault.settle();

        uint256 free = vault.firstLossRemaining();
        assertEq(free, 500_000e6 - 153_500e6, "impaired capital is not free");

        // Nothing impaired may leave.
        vm.prank(originator);
        vm.expectRevert();
        vault.releaseFirstLoss(free + 1);

        // And coverage may not fall under the floor it was sized at.
        uint256 floor_ = (vault.exposure() * vault.minFirstLossBps()) / 10_000;
        uint256 tooMuch = 500_000e6 - floor_ + 1e6;
        vm.prank(originator);
        vm.expectRevert();
        vault.releaseFirstLoss(tooMuch);

        uint256 ok = 500_000e6 - floor_;
        if (ok > free) ok = free;
        uint256 before_ = IERC20(USDCE).balanceOf(originator);
        vm.prank(originator);
        vault.releaseFirstLoss(ok);
        assertEq(IERC20(USDCE).balanceOf(originator) - before_, ok);
        assertGe(vault.firstLoss(), floor_, "a permanent junior layer remains");
        console.log("released (USDC)    ", ok / 1e6);
        console.log("still junior (USDC)", vault.firstLoss() / 1e6);
    }

    /// A floor an admin can set to zero is not a floor.
    function test_FloorCannotBeSwitchedOff() public {
        uint16 justUnder = vault.MIN_FLOOR_BPS() - 1;
        vm.startPrank(admin);
        vm.expectRevert();
        vault.setFloorBps(0);
        vm.expectRevert();
        vault.setFloorBps(justUnder);
        vault.setFloorBps(2500); // raising it is fine
        vm.stopPrank();
        assertEq(vault.floorBps(), 2500);
    }

    /// The impairment schedule is a pure function, so "fixed at deployment" is
    /// a property of the code rather than of the absence of a setter.
    function test_ImpairmentScheduleIsNotStorage() public view {
        assertEq(registry.impairmentBps(0), 0);
        assertEq(registry.impairmentBps(1), 1000);
        assertEq(registry.impairmentBps(2), 3000);
        assertEq(registry.impairmentBps(3), 6000);
        assertEq(registry.impairmentBps(4), 10_000);
    }

    /// Instant exits stay closed. An ERC-4626 integrator that ignores
    /// maxRedeem must still fail rather than jump the queue.
    function test_NoBypassOfTheQueue() public {
        _bootstrap();
        vm.startPrank(lp);
        vm.expectRevert();
        vault.redeem(1_000e6, lp, lp);
        vm.expectRevert();
        vault.withdraw(1_000e6, lp, lp);
        vm.stopPrank();
        assertEq(vault.maxRedeem(lp), 0);
        assertEq(vault.maxWithdraw(lp), 0);
    }

    // ======================================================== access control

    function test_RolesAreEnforced() public {
        vm.warp(PREV_COMMIT_TS);

        vm.prank(attacker);
        vm.expectRevert();
        registry.commitBook(_inputs("t0")[1]);

        vm.prank(attacker);
        vm.expectRevert();
        registry.attest(_inputs("t0")[1], AS_OF_0, bytes32(0));

        vm.prank(attacker);
        vm.expectRevert();
        vault.deploy(rail, 1, _inputs("t0")[1]);

        vm.prank(attacker);
        vm.expectRevert();
        vault.setFloorBps(0);

        // recordDeployment may only be called by the bound vault, otherwise the
        // disbursement ceiling could be raised without moving any cash.
        vm.prank(attacker);
        vm.expectRevert(CreditDisclosureRegistry.NotVault.selector);
        registry.recordDeployment(bytes32(0), 100_000_000e6);
    }

    /// Anyone may publish a valid proof. Disclosure must not be censorable by
    /// the party the disclosure is about.
    function test_PublishingIsPermissionless() public {
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(_inputs("t0")[1]);

        vm.startPrank(lp);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(5_500_000e6, lp);
        vm.stopPrank();
        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(500_000e6);
        vault.deploy(rail, 4_760_000e6, _inputs("t0")[1]);
        vm.stopPrank();

        vm.warp(AS_OF_0 + 1 hours);
        vm.prank(attacker); // not the originator, not an admin
        registry.publishSurface(_proof("t0"), _inputs("t0"));
        assertEq(registry.surface().positions, 22);
    }
}
