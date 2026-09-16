// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IRiskSurface} from "./IRiskSurface.sol";

interface IZkVerifyAggregation {
    function verifyProofAggregation(
        uint256 domainId,
        uint256 aggregationId,
        bytes32 leaf,
        bytes32[] calldata merklePath,
        uint256 leafCount,
        uint256 index
    ) external view returns (bool);
}

/// @title ZkVerifyRiskSurface
/// @notice The same risk surface, admitted on a different route.
///
/// The registry verifies an UltraHonk proof on Horizen directly, which costs
/// about 2.36 M gas. This contract takes the other road: the proof is verified
/// once on zkVerify, batched with unrelated proofs into a Merkle tree, and the
/// root of that tree is relayed to this chain. Admitting a surface then costs a
/// Merkle inclusion check rather than a pairing check.
///
/// The trade is not free. Direct verification depends on nothing beyond the
/// chain it runs on. This route depends on zkVerify verifying honestly, on its
/// relayer posting the root, and on the aggregation contract being live here.
/// Section 2.3 of the architecture document is why Phase 1 takes the first road
/// and treats this one as the option it is, and the gas numbers in the test are
/// what that choice costs.
contract ZkVerifyRiskSurface {
    /// @dev zkVerify identifies the proving system by hashing its name. The
    ///      UltraHonk pallet uses keccak256("ultrahonk") as its context.
    bytes32 public constant PROVING_SYSTEM_ID = keccak256("ultrahonk");

    /// @notice The zkVerify aggregation contract on this chain.
    IZkVerifyAggregation public immutable zkVerify;

    /// @notice keccak256 over the SCALE-encoded verification key, as the
    ///         UltraHonk pallet computes it for its V0_84 variant. Binding it at
    ///         deployment is what stops a valid proof of a different statement
    ///         being presented here.
    bytes32 public immutable vkHash;

    /// @notice The zkVerify domain our proofs are aggregated in.
    uint256 public immutable domainId;

    IRiskSurface.Surface private _surface;
    uint256 public admittedAggregationId;

    event SurfaceAdmitted(uint256 indexed aggregationId, bytes32 indexed bookRoot, uint64 asOf);

    error NotAggregated();
    error WrongPublicInputCount();
    error SurfaceNotMonotonic();

    constructor(address zkVerify_, bytes32 vkHash_, uint256 domainId_) {
        zkVerify = IZkVerifyAggregation(zkVerify_);
        vkHash = vkHash_;
        domainId = domainId_;
    }

    /// @notice The leaf zkVerify puts in its tree for one of our proofs.
    /// @dev    keccak256(provingSystemId, vkHash, keccak256(publicInputs)). The
    ///         public inputs are the 17 field elements the circuit returns, in
    ///         circuit order, each a big-endian 32-byte word.
    function leafFor(bytes32[] calldata publicInputs) public view returns (bytes32) {
        if (publicInputs.length != 17) revert WrongPublicInputCount();
        return keccak256(abi.encodePacked(PROVING_SYSTEM_ID, vkHash, keccak256(abi.encodePacked(publicInputs))));
    }

    /// @notice Admit a risk surface whose proof zkVerify has already verified.
    /// @dev    No pairing check happens here. The only cryptography is a Merkle
    ///         path against a root this chain was handed.
    function admit(
        uint256 aggregationId,
        bytes32[] calldata merklePath,
        uint256 leafCount,
        uint256 index,
        bytes32[] calldata publicInputs
    ) external {
        bytes32 leaf = leafFor(publicInputs);

        if (!zkVerify.verifyProofAggregation(domainId, aggregationId, leaf, merklePath, leafCount, index)) {
            revert NotAggregated();
        }

        uint64 asOf = uint64(uint256(publicInputs[0]));
        if (_surface.asOf != 0 && asOf <= _surface.asOf) revert SurfaceNotMonotonic();

        uint128[5] memory ladder;
        uint128[5] memory delinquent;
        for (uint256 i = 0; i < 5; ++i) {
            ladder[i] = uint128(uint256(publicInputs[4 + i]));
            delinquent[i] = uint128(uint256(publicInputs[10 + i]));
        }

        _surface = IRiskSurface.Surface({
            bookRoot: publicInputs[1],
            asOf: asOf,
            positions: uint64(uint256(publicInputs[2])),
            maxCommittedTs: uint64(uint256(publicInputs[16])),
            totalPrincipal: uint128(uint256(publicInputs[3])),
            dueNext30d: uint128(uint256(publicInputs[9])),
            top1: uint128(uint256(publicInputs[15])),
            ladder: ladder,
            delinquent: delinquent
        });
        admittedAggregationId = aggregationId;

        emit SurfaceAdmitted(aggregationId, publicInputs[1], asOf);
    }

    function surface() external view returns (IRiskSurface.Surface memory) {
        return _surface;
    }
}
