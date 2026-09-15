// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HonkVerifier} from "../src/HonkVerifier.sol";
import {DeltaVerifier} from "../src/DeltaVerifier.sol";
import {CreditDisclosureRegistry} from "../src/CreditDisclosureRegistry.sol";
import {AgamaCreditVault} from "../src/AgamaCreditVault.sol";
import {IRiskSurface} from "../src/IRiskSurface.sol";

/// @notice Runs the whole disclosure cycle against a fork of Horizen mainnet
///         (chain 26514, OP Stack L3 on Base) so every gas number below is a
///         real number on the real chain, not a local estimate.
contract HorizenForkTest is Test {
    // Live Horizen mainnet addresses.
    address constant USDCE = 0xDF7108f8B10F9b9eC1aba01CCa057268cbf86B6c;
    address constant PUREFI_VERIFIER = 0x681Edd4906e2a0a277E2A6c394A4595f83e1329c;
    uint256 constant HORIZEN_CHAIN_ID = 26514;

    uint64 constant AS_OF_0 = 1789500000;
    uint64 constant AS_OF_1 = AS_OF_0 + 30 days;
    uint64 constant PREV_COMMIT_TS = AS_OF_0 - 1 days; // genesis commit, matches the circuit

    HonkVerifier verifier;
    DeltaVerifier deltaVerifier;
    CreditDisclosureRegistry registry;
    AgamaCreditVault vault;

    address admin = makeAddr("admin");
    address originator = makeAddr("originator");
    address auditor = makeAddr("auditor");
    address lpA = makeAddr("lpA");
    address lpB = makeAddr("lpB");
    address borrowerRail = makeAddr("borrowerRail");

    function setUp() public {
        vm.createSelectFork(vm.envOr("HORIZEN_RPC", string("https://horizen.calderachain.xyz/http")));
        assertEq(block.chainid, HORIZEN_CHAIN_ID, "not on Horizen mainnet");

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

        deal(USDCE, lpA, 3_500_000e6);
        deal(USDCE, lpB, 2_500_000e6);
        deal(USDCE, originator, 1_000_000e6);
        deal(USDCE, borrowerRail, 1_000_000e6);
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

    function _rootOf(string memory s) internal view returns (bytes32) {
        return _inputs(s)[1];
    }

    // ------------------------------------------------------------ the cycle

    /// The originator commits terms, deploys cash, proves a risk surface, and
    /// the vault marks itself from the proof. No one asserts a NAV.
    function test_FullDisclosureCycle() public {
        bytes32 root = _rootOf("t0");

        vm.warp(AS_OF_0 - 1 days);
        vm.prank(originator);
        uint256 g = gasleft();
        registry.commitBook(root);
        console.log("gas commitBook           ", g - gasleft());

        // LPs fund the vault before anything is disbursed.
        vm.startPrank(lpA);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        g = gasleft();
        vault.deposit(3_300_000e6, lpA);
        console.log("gas deposit (first)      ", g - gasleft());
        vm.stopPrank();

        vm.startPrank(lpB);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(2_200_000e6, lpB);
        vm.stopPrank();

        // Originator posts first-loss capital, junior to every depositor.
        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(500_000e6);

        // Cash only moves against an already-committed book.
        vault.deploy(borrowerRail, 4_760_000e6, root);
        vm.stopPrank();

        assertEq(vault.buffer(), 740_000e6, "buffer after deployment");

        // Publish the proven risk surface.
        vm.warp(AS_OF_0 + 1 hours);
        g = gasleft();
        registry.publishSurface(_proof("t0"), _inputs("t0"));
        uint256 gasPublish = g - gasleft();
        console.log("gas publishSurface (ZK)  ", gasPublish);

        IRiskSurface.Surface memory s = registry.surface();
        assertEq(s.bookRoot, root);
        assertEq(s.asOf, AS_OF_0);
        assertEq(s.positions, 22);
        assertEq(s.totalPrincipal, 4_760_000e6);
        assertEq(s.dueNext30d, 33_487.5e6);
        assertEq(s.top1, 1_050_000e6);

        console.log("positions                ", s.positions);
        console.log("principal (USDC)         ", uint256(s.totalPrincipal) / 1e6);
        console.log("concentration (bps)      ", registry.concentration() / 1e14);
        console.log("impaired (USDC)          ", registry.impairedPrincipal() / 1e6);
        console.log("NAV (USDC)               ", vault.totalAssets() / 1e6);

        // NAV is derived, not asserted: buffer + principal - impairment + first-loss absorption.
        uint256 impaired = registry.impairedPrincipal();
        assertEq(impaired, 43_500e6 + 110_000e6, "mechanical impairment at t0");
        assertEq(vault.totalAssets(), 740_000e6 + 4_760_000e6, "first-loss absorbs t0 impairment");
    }

    /// The reviewer's case: the book was signed clean and the loans were already
    /// bad. The proof still passes. The vault still misses the calendar it
    /// published a month earlier, in public, with nobody's cooperation required.
    function test_BadBookFailsItsOwnCalendar() public {
        // First-loss sized at 4% of the book, below the impairment the book
        // reaches one period on, so the waterfall is visible end to end.
        _bootstrap(200_000e6);

        uint64 e0 = registry.epochOf(AS_OF_0);
        assertEq(registry.scheduledFor(e0), 33_487.5e6, "forward calendar written in advance");

        // Only part of the promised cash arrives on-chain.
        vm.warp(AS_OF_0 + 20 days);
        vm.startPrank(borrowerRail);
        IERC20(USDCE).approve(address(registry), type(uint256).max);
        registry.recordCollection(12_000e6);
        vm.stopPrank();

        uint256 ratio = registry.performanceRatio(e0);
        console.log("epoch 0 scheduled (USDC) ", registry.scheduledFor(e0) / 1e6);
        console.log("epoch 0 realized  (USDC) ", registry.realizedFor(e0) / 1e6);
        console.log("epoch 0 performance (bps)", ratio / 1e14);

        assertLt(ratio, 0.4e18, "a clean signature does not produce cash");

        // One period on, the same positions prove a worse surface. A revision is
        // itself a commitment: the new root is published before it is proven.
        vm.warp(AS_OF_1 + 30 minutes);
        vm.prank(originator);
        uint256 gRev = gasleft();
        registry.commitRevision(_proof("delta"), _inputs("delta"));
        console.log("gas commitRevision (ZK)  ", gRev - gasleft());

        vm.warp(AS_OF_1 + 1 hours);
        uint256 navBefore = vault.totalAssets();
        uint256 flBefore = vault.firstLossRemaining();
        registry.publishSurface(_proof("t1"), _inputs("t1"));
        uint256 navAfter = vault.totalAssets();

        console.log("impaired at t0 (USDC)    ", uint256(153_500));
        console.log("impaired at t1 (USDC)    ", registry.impairedPrincipal() / 1e6);
        console.log("first-loss left t0 (USDC)", flBefore / 1e6);
        console.log("first-loss left t1 (USDC)", vault.firstLossRemaining() / 1e6);
        console.log("NAV before t1 (USDC)     ", navBefore / 1e6);
        console.log("NAV after  t1 (USDC)     ", navAfter / 1e6);
        console.log("price per share (1e6)    ", vault.convertToAssets(1e6));

        assertGt(registry.impairedPrincipal(), 153_500e6, "impairment rose on the same book");
        assertEq(vault.firstLossRemaining(), 0, "originator junior capital consumed first");
        assertLt(navAfter, navBefore, "depositor NAV fell without anyone marking it");
        assertLt(vault.convertToAssets(1e6), 1e6, "share price below par, mechanically");
    }

    /// A surface may never be proven against a book the chain has not seen, and
    /// no leaf may claim it was committed after its own root was.
    function test_RejectsUncommittedAndBackdatedBooks() public {
        vm.warp(AS_OF_0 + 1 hours);
        vm.expectRevert(CreditDisclosureRegistry.RootNotCommitted.selector);
        registry.publishSurface(_proof("t0"), _inputs("t0"));

        // Commit only after the as-of date the surface claims: backdating.
        vm.prank(originator);
        registry.commitBook(_rootOf("t0"));
        vm.expectRevert(CreditDisclosureRegistry.AsOfBeforeCommit.selector);
        registry.publishSurface(_proof("t0"), _inputs("t0"));
    }

    /// The exit queue is public state and pays one ratio to everyone, so being
    /// first in line is worth nothing and there is no reason to run.
    function test_QueueIsProRataAndPublic() public {
        _bootstrap(500_000e6);

        vm.warp(AS_OF_0 + 2 days);
        uint256 sharesA = vault.balanceOf(lpA);
        uint256 sharesB = vault.balanceOf(lpB);

        vm.prank(lpA);
        vault.requestRedeem(sharesA); // first in line
        vm.prank(lpB);
        vault.requestRedeem(sharesB); // second, one block later

        assertEq(vault.queueDepth(), 2, "queue depth is public");
        console.log("queued assets (USDC)     ", vault.queuedAssets() / 1e6);
        console.log("buffer        (USDC)     ", vault.buffer() / 1e6);
        console.log("coverage ratio (bps)     ", vault.coverageRatio() / 1e14);

        assertLt(vault.coverageRatio(), 1e18, "vault warns it cannot pay everyone");

        uint256 beforeA = IERC20(USDCE).balanceOf(lpA);
        uint256 beforeB = IERC20(USDCE).balanceOf(lpB);

        uint256 g = gasleft();
        uint256 ratio = vault.settle();
        console.log("gas settle (2 tickets)   ", g - gasleft());
        console.log("settlement ratio (bps)   ", ratio / 1e14);

        uint256 paidA = IERC20(USDCE).balanceOf(lpA) - beforeA;
        uint256 paidB = IERC20(USDCE).balanceOf(lpB) - beforeB;
        console.log("paid A (USDC)            ", paidA / 1e6);
        console.log("paid B (USDC)            ", paidB / 1e6);

        // A asked for 3.3m, B for 2.2m. Both received the same fraction of what
        // they asked for, despite A queueing first: paidA/3.3 == paidB/2.2.
        assertApproxEqRel(paidA * 22, paidB * 33, 1e12, "pro-rata regardless of position");
        assertLt(ratio, 1e18, "partial fill, no first-mover advantage");
    }

    /// Independent verification is recorded on-chain: who looked, when, and at
    /// which book. A depositor cannot read the book but can read its absence.
    function test_VerifierAccessIsPublic() public {
        _bootstrap(500_000e6);
        assertEq(registry.verificationAge(), type(uint256).max, "nobody has looked yet");

        vm.warp(AS_OF_0 + 3 days);
        vm.prank(auditor);
        registry.attest(_rootOf("t0"), AS_OF_0, keccak256("sampled 30 of 22 positions, no exception"));

        assertEq(registry.attestationCount(), 1);
        assertEq(registry.verificationAge(), 0);

        vm.warp(AS_OF_0 + 100 days);
        assertGt(registry.verificationAge(), 90 days, "stale verification is itself a public signal");
    }

    /// PureFi is live on Horizen mainnet. Gate deposits on it and a
    /// non-compliant deposit cannot exist as a transaction.
    function test_PureFiIsLiveOnHorizen() public {
        assertGt(PUREFI_VERIFIER.code.length, 0, "PureFi verifier deployed on Horizen");

        vm.prank(admin);
        vault.setCompliance(PUREFI_VERIFIER);

        vm.startPrank(lpA);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.depositWithCompliance(1_000e6, lpA, hex"deadbeef");
        vm.stopPrank();
    }

    function test_ReportLiveChainCosts() public view {
        uint256 gp = tx.gasprice > 0 ? tx.gasprice : 1_000_764; // live eth_gasPrice
        console.log("chain id                 ", block.chainid);
        console.log("fork block               ", block.number);
        console.log("gas price (wei)          ", gp);
        console.log("USDC.e supply (USDC)     ", IERC20(USDCE).totalSupply() / 1e6);
    }

    // ---------------------------------------------------------------- helper

    function _bootstrap(uint256 firstLossAmount) internal {
        bytes32 root = _rootOf("t0");
        vm.warp(PREV_COMMIT_TS);
        vm.prank(originator);
        registry.commitBook(root);

        vm.startPrank(lpA);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(3_300_000e6, lpA);
        vm.stopPrank();

        vm.startPrank(lpB);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.deposit(2_200_000e6, lpB);
        vm.stopPrank();

        vm.startPrank(originator);
        IERC20(USDCE).approve(address(vault), type(uint256).max);
        vault.postFirstLoss(firstLossAmount);
        vault.deploy(borrowerRail, 4_760_000e6, root);
        vm.stopPrank();

        vm.warp(AS_OF_0 + 1 hours);
        registry.publishSurface(_proof("t0"), _inputs("t0"));
    }
}
