// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ZkVerifyRiskSurface, IZkVerifyAggregation} from "../src/ZkVerifyRiskSurface.sol";
import {AggregationStandIn} from "../src/AggregationStandIn.sol";
import {IRiskSurface} from "../src/IRiskSurface.sol";

/// @notice Two things are being checked here, and they are different in kind.
///
/// What is ours: the leaf we build for zkVerify's tree, and the decoding of a
/// surface once zkVerify says the proof was verified. Those are tested directly.
///
/// What is theirs: the aggregation contract deployed on Base Sepolia. That is
/// probed live rather than mocked, so the ABI we target is the one that answers.
/// We do not reimplement their Merkle check; we call it.
contract ZkVerifyTest is Test {
    address constant ZKV_BASE_SEPOLIA = 0x312468EbF274F1f584d93d0CCA8458cC91460FC0;
    uint256 constant DOMAIN = 0;

    /// The vk hash zkVerify itself reports for our key, via session.getVkHash.
    /// Not keccak256 of the raw vk bytes: the pallet hashes the SCALE-encoded
    /// versioned enum, which carries a discriminant and a length prefix.
    bytes32 constant VK_HASH = 0x5da1b785ba7eb5ff008935ce60182447b79a4d171b1b1f1f0722e5e8fc7c9b78;

    /// The statement zkVerify returned when it verified this exact proof, in
    /// submission 0x49ed9bbc on Volta. Ground truth for the leaf formula.
    bytes32 constant REAL_STATEMENT = 0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730;

    /// The root zkVerify published for domain 10 aggregation 2, which contains
    /// that statement as its only leaf. Block 0x761aa9e3.
    bytes32 constant REAL_ROOT = 0xb2ee6f0eb55cd0a4452c30da159adcfda7e6c0f227a22cb30c39229416946564;

    ZkVerifyRiskSurface adapter;

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        adapter = new ZkVerifyRiskSurface(ZKV_BASE_SEPOLIA, VK_HASH, DOMAIN);
    }

    function _inputs() internal view returns (bytes32[] memory out) {
        bytes memory raw = vm.readFileBinary("test/fixtures/public_inputs_t0.bin");
        out = new bytes32[](raw.length / 32);
        for (uint256 i = 0; i < out.length; ++i) {
            bytes32 w;
            assembly {
                w := mload(add(add(raw, 0x20), mul(i, 0x20)))
            }
            out[i] = w;
        }
    }

    /// The aggregation contract is deployed, and it answers the exact call our
    /// adapter makes. This runs against Base Sepolia, not against a mock.
    function test_LiveZkVerifyContractSpeaksOurInterface() public view {
        assertEq(block.chainid, 84532, "not on Base Sepolia");
        assertGt(ZKV_BASE_SEPOLIA.code.length, 0, "no code at the zkVerify address");
        console.log("zkVerify bytecode on Base Sepolia", ZKV_BASE_SEPOLIA.code.length);

        bytes32[] memory path = new bytes32[](0);
        bool verified = IZkVerifyAggregation(ZKV_BASE_SEPOLIA).verifyProofAggregation(
            DOMAIN, 1, bytes32(0), path, 1, 0
        );
        assertFalse(verified, "an aggregation that was never posted must not verify");
        console.log("verifyProofAggregation answers, and refuses an unposted aggregation");
    }

    /// The decisive test. Our leaf must equal the statement zkVerify actually
    /// returned for this proof, not merely match the published formula, which
    /// describes three components where the pallet hashes four.
    function test_LeafReproducesTheStatementZkVerifyReturned() public view {
        bytes32[] memory pi = _inputs();
        assertEq(pi.length, 17, "the circuit emits 17 public inputs");

        bytes32 leaf = adapter.leafFor(pi);
        console.log("leaf we compute");
        console.logBytes32(leaf);
        console.log("statement zkVerify returned on Volta");
        console.logBytes32(REAL_STATEMENT);
        assertEq(leaf, REAL_STATEMENT, "leaf does not reproduce the real statement");
    }

    /// Dropping the version hash, which is what the documentation's three-part
    /// description leads you to do, produces a leaf that is in no tree anywhere.
    function test_TheThreePartFormulaFromTheDocsIsWrong() public view {
        bytes32[] memory pi = _inputs();
        bytes32 threeParts = keccak256(
            abi.encodePacked(keccak256("ultrahonk"), VK_HASH, keccak256(abi.encodePacked(pi)))
        );
        assertTrue(threeParts != REAL_STATEMENT, "the docs formula would have worked after all");
        console.log("what the documented three-part formula gives");
        console.logBytes32(threeParts);
    }

    /// The whole path, against the root zkVerify actually published. The
    /// aggregation contract here is a stand-in holding that real root, because
    /// no zkVerify domain relays to any EVM chain today: on both Volta and
    /// mainnet, hp_dispatch::Destination has one variant and it is None. One hop
    /// is simulated, the rest is the real thing.
    function test_RealAggregationAdmitsTheRealSurface() public {
        AggregationStandIn standIn = new AggregationStandIn(10, 2, REAL_ROOT);
        ZkVerifyRiskSurface consumer = new ZkVerifyRiskSurface(address(standIn), VK_HASH, 10);

        bytes32[] memory pi = _inputs();
        bytes32[] memory emptyPath = new bytes32[](0);

        uint256 g = gasleft();
        consumer.admit(2, emptyPath, 1, 0, pi);
        console.log("gas to admit against the real zkVerify root", g - gasleft());

        IRiskSurface.Surface memory s = consumer.surface();
        assertEq(s.positions, 22);
        assertEq(s.totalPrincipal, 4_760_000e6);
        assertEq(s.top1, 1_050_000e6);
        assertEq(consumer.admittedAggregationId(), 2);
    }

    /// A surface that was never aggregated is refused by the same path.
    function test_RealRootRefusesASurfaceItDoesNotCover() public {
        AggregationStandIn standIn = new AggregationStandIn(10, 2, REAL_ROOT);
        ZkVerifyRiskSurface consumer = new ZkVerifyRiskSurface(address(standIn), VK_HASH, 10);

        bytes32[] memory pi = _inputs();
        pi[3] = bytes32(uint256(9_999_999e6)); // inflate the principal
        bytes32[] memory emptyPath = new bytes32[](0);

        vm.expectRevert(ZkVerifyRiskSurface.NotAggregated.selector);
        consumer.admit(2, emptyPath, 1, 0, pi);
    }

    /// zkVerify's tree hashes the leaf at the bottom, so a single-leaf
    /// aggregation roots at keccak256(leaf) rather than at the leaf itself.
    /// Worth pinning, because it is the shape a one-proof batch takes and it is
    /// not what a reader of the interface would assume.
    function test_SingleLeafAggregationRootsAtKeccakOfTheLeaf() public view {
        bytes32[] memory pi = _inputs();
        assertEq(adapter.leafFor(pi), REAL_STATEMENT);
        assertEq(keccak256(abi.encodePacked(REAL_STATEMENT)), REAL_ROOT, "root is not keccak of the leaf");
    }

    /// And hashing the raw vk bytes instead of the SCALE-encoded versioned key is
    /// the other way to get a leaf that never matches.
    function test_NaiveVkHashIsWrong() public view {
        bytes32 naive = keccak256(vm.readFileBinary("test/fixtures/zkv_vk.bin"));
        assertTrue(naive != VK_HASH, "raw vk hash happened to match");
        console.log("keccak256 of the raw vk bytes, which is not what the pallet uses");
        console.logBytes32(naive);
    }

    /// Changing a single published number changes the leaf, so a surface cannot
    /// be edited after zkVerify has attested to it.
    function test_TamperingWithAPublishedNumberChangesTheLeaf() public view {
        bytes32[] memory pi = _inputs();
        bytes32 honest = adapter.leafFor(pi);

        pi[14] = bytes32(0); // wipe the 90-plus delinquency bucket
        assertTrue(adapter.leafFor(pi) != honest, "the leaf did not move");
        assertTrue(adapter.leafFor(pi) != REAL_STATEMENT, "a tampered surface reached a real statement");
    }

    /// Once zkVerify says the proof was verified, the surface decodes to the same
    /// numbers the registry reads on Horizen.
    function test_AdmittedSurfaceDecodesToTheSameNumbers() public {
        bytes32[] memory pi = _inputs();
        bytes32[] memory path = new bytes32[](4);
        uint256 aggId = 99;

        vm.mockCall(
            ZKV_BASE_SEPOLIA,
            abi.encodeWithSelector(
                IZkVerifyAggregation.verifyProofAggregation.selector,
                DOMAIN, aggId, adapter.leafFor(pi), path, uint256(16), uint256(3)
            ),
            abi.encode(true)
        );

        // Cold: the surface has never been written, so this pays for thirteen
        // fresh storage words as well as the check.
        uint256 g = gasleft();
        adapter.admit(aggId, path, 16, 3, pi);
        uint256 cold = g - gasleft();

        IRiskSurface.Surface memory s = adapter.surface();
        assertEq(s.positions, 22);
        assertEq(s.totalPrincipal, 4_760_000e6);
        assertEq(s.dueNext30d, 33_487.5e6);
        assertEq(s.top1, 1_050_000e6);
        assertEq(s.delinquent[4], 110_000e6);

        // The check on its own, with no storage written.
        g = gasleft();
        adapter.leafFor(pi);
        uint256 leafOnly = g - gasleft();

        console.log("admitting a surface via zkVerify, cold storage", cold);
        console.log("  of which the leaf computation is about       ", leafOnly);
        console.log("  the rest is writing the surface, which the direct route pays too");
        console.log("  and it excludes zkVerify's own Merkle check, a few keccaks per level");
        console.log("");
        console.log("verifying the same proof directly on Horizen   2364745");
        console.log("  measured on testnet, see deployment/deployment-testnet.md");
        console.log("");
        console.log("So the honest comparison is the verification component alone:");
        console.log("  a pairing check over a 2^18 circuit, against a Merkle path.");
        console.log("  Roughly 2.1 M gas against a few thousand.");
    }

    /// A surface admitted here cannot walk backwards either.
    function test_AdmittedSurfacesStayMonotonic() public {
        bytes32[] memory pi = _inputs();
        bytes32[] memory path = new bytes32[](0);

        vm.mockCall(
            ZKV_BASE_SEPOLIA,
            abi.encodeWithSelector(IZkVerifyAggregation.verifyProofAggregation.selector),
            abi.encode(true)
        );
        adapter.admit(1, path, 1, 0, pi);

        vm.expectRevert(ZkVerifyRiskSurface.SurfaceNotMonotonic.selector);
        adapter.admit(2, path, 1, 0, pi);
    }

    /// Without an aggregation behind it, nothing is admitted.
    function test_NothingIsAdmittedWithoutAnAggregation() public {
        bytes32[] memory pi = _inputs();
        bytes32[] memory path = new bytes32[](0);
        vm.expectRevert(ZkVerifyRiskSurface.NotAggregated.selector);
        adapter.admit(1, path, 1, 0, pi);
    }
}
