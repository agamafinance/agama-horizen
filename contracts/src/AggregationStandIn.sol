// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title AggregationStandIn
/// @notice Holds an aggregation root on a chain zkVerify does not relay to yet,
///         so the consumer path can be exercised end to end.
///
/// This exists because of a gap we could not close from the outside. A zkVerify
/// domain carries a `delivery` field, and on both Volta and mainnet today the
/// `hp_dispatch::Destination` type has exactly one variant: `None`. No domain
/// setting relays a root anywhere. Roots reach EVM chains through a relayer
/// zkVerify operates, which an application cannot self-serve.
///
/// So the root stored here is a real one, `0xb2ee6f0e...`, published by zkVerify
/// for domain 10 aggregation 2 at block `0x761aa9e3...`, copied across by us
/// rather than relayed by them. Everything downstream of it is genuine: the leaf
/// our consumer computes, the inclusion check, the decoding. What is simulated is
/// one hop, and it is named rather than hidden.
///
/// It implements the same interface as zkVerify's own aggregation contract, so
/// the consumer cannot tell the difference and needs no test-only branch.
contract AggregationStandIn {
    mapping(uint256 => mapping(uint256 => bytes32)) public proofsAggregations;

    event AggregationPosted(uint256 indexed domainId, uint256 indexed aggregationId, bytes32 root);

    constructor(uint256 domainId, uint256 aggregationId, bytes32 root) {
        proofsAggregations[domainId][aggregationId] = root;
        emit AggregationPosted(domainId, aggregationId, root);
    }

    /// @dev Mirrors zkVerify's entry point. Their implementation uses EigenDA's
    ///      Merkle library to match Substrate's binary tree; this reproduces the
    ///      same walk, hashing the leaf at the bottom as their single-leaf root
    ///      demonstrates.
    function verifyProofAggregation(
        uint256 domainId,
        uint256 aggregationId,
        bytes32 leaf,
        bytes32[] calldata merklePath,
        uint256 leafCount,
        uint256 index
    ) external view returns (bool) {
        bytes32 root = proofsAggregations[domainId][aggregationId];
        if (root == bytes32(0)) return false;
        if (index >= leafCount) return false;

        bytes32 node = keccak256(abi.encodePacked(leaf));
        uint256 i = index;
        for (uint256 d = 0; d < merklePath.length; ++d) {
            node = (i & 1 == 0)
                ? keccak256(abi.encodePacked(node, merklePath[d]))
                : keccak256(abi.encodePacked(merklePath[d], node));
            i >>= 1;
        }
        return node == root;
    }
}
