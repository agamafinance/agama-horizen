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
    /// @dev zkVerify identifies the proving system by hashing its name.
    bytes32 public constant PROVING_SYSTEM_ID = keccak256("ultrahonk");

    /// @dev sha256("ultrahonk:v0.84"), the pallet's hash for the proof version.
    ///      The published documentation describes the statement as three parts,
    ///      context, vk and public inputs. The pallet hashes four: this version
    ///      hash sits between the vk and the inputs. Omitting it produces a leaf
    ///      that is wrong in a way nothing tells you about, so it is pinned here
    ///      against a statement zkVerify actually returned.
    ///      Source: verifiers/ultrahonk/src/lib.rs, verifier_version_hash.
    bytes32 public constant VERSION_HASH_V0_84 =
        0x4966cd7801ae9ef9d7afb52ec3de92f0693e720f58c5c8ecfb23d85b0934f018;

    /// @notice The zkVerify aggregation contract on this chain.
    IZkVerifyAggregation public immutable zkVerify;

    /// @notice keccak256 over the SCALE-encoded versioned verification key.
    /// @dev    Not keccak256 of the raw vk bytes: the pallet hashes
    ///         `VersionedVk::encode()`, which carries the enum discriminant and a
    ///         length prefix. The two differ, and the naive one silently produces
    ///         a leaf that is never in any tree. Take this value from zkVerify's
    ///         own RPC, `session.getVkHash`, rather than computing it.
    ///         Binding it at deployment is what stops a valid proof of a
    ///         different statement being presented here.
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
    /// @dev    keccak256(context, vkHash, versionHash, keccak256(publicInputs)),
    ///         which is `compute_statement_hash` in pallets/verifiers. The public
    ///         inputs are the 17 field elements the circuit returns, in circuit
    ///         order, each a big-endian 32-byte word, concatenated with no
    ///         separator and no length prefix.
    ///
    ///         This is checked against a statement zkVerify returned for a real
    ///         submission rather than against the documentation, which describes
    ///         three components where the code hashes four.
    function leafFor(bytes32[] calldata publicInputs) public view returns (bytes32) {
        if (publicInputs.length != 17) revert WrongPublicInputCount();
        return keccak256(
            abi.encodePacked(
                PROVING_SYSTEM_ID,
                vkHash,
                VERSION_HASH_V0_84,
                keccak256(abi.encodePacked(publicInputs))
            )
        );
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
