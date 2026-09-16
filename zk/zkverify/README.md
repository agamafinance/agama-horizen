# zkVerify

The registry verifies an UltraHonk proof on Horizen directly. This folder is the
other road: the proof is verified once on zkVerify, batched into a Merkle tree,
and the root relayed to an EVM chain, where a contract admits the surface on an
inclusion check rather than a pairing check.

We built it rather than reasoning about it, because the trade-off is not obvious
until it is measured.

## What happened

zkVerify verified our risk-surface proof and published the aggregation. Real
transactions on Volta:

| | |
| --- | --- |
| Submission | `0x49ed9bbc09931f5043cef404536e73b24aab5405d70a1aa38daa82feb2d96ba0` |
| Statement | `0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730` |
| Domain, aggregation | 10, 2 |
| Published at | `0x761aa9e3d50849d1d01fe39e21847091ab40feef72bfe29d3d8db48a9de2fe1f` |
| Root | `0xb2ee6f0eb55cd0a4452c30da159adcfda7e6c0f227a22cb30c39229416946564` |

The surface behind that statement is the reference book: 22 positions, 4,760,000
USDC.

Then, on Base Sepolia, our consumer recomputes that statement on-chain from the
seventeen public inputs and the verification key bound at deployment, and admits
the surface against the published root. Addresses, transaction and the numbers
anyone can read back are in
[`../../deployment/base-sepolia.md`](../../deployment/base-sepolia.md).

## What it costs

| | Gas |
| --- | ---: |
| Verify the proof directly on Horizen | **2,364,745** |
| Admit the same surface from an aggregation, on Base Sepolia | **266,041** |

Both routes write the same thirteen words of risk surface, so the comparison that
matters is the verification component alone: a pairing check over a 2^18 circuit
against a Merkle path, roughly 2.1 M gas against a few thousand.

An order of magnitude is real. On Horizen at 0.001 gwei it is also the difference
between two thirds of a cent and a tenth of one, which is why Phase 1 verifies
directly. On a chain with L1 gas prices the arithmetic reverses, and the same
consumer works there unchanged.

## Why it is an option and not a dependency

**There is no aggregation contract on Horizen L3.** A Horizen contract cannot
consume a zkVerify aggregation today.

**And no domain relays a root by configuration.** On Volta and on zkVerify
mainnet alike, `hp_dispatch::Destination` has one variant, `None`. That leg runs
on a relayer zkVerify operates, not on anything an application sets up. So on
Base Sepolia the root was copied across by hand into a stand-in contract, and
everything downstream of that hop is genuine. The second deployment proves the
point by reverting with `NotAggregated` when pointed at zkVerify's real contract.

## Running it

```sh
cd .. && ./prove.sh --zkverify     # zk-flavour artefacts, built with bb 0.84
cd zkverify && npm i

node account.mjs                   # creates .env, prints the address for the faucet
node submit.mjs                    # verifies the proof on zkVerify
DOMAIN_ID=10 AGGREGATION_ID=n STATEMENT=0x... node publish.mjs
```

The pallet is particular about its inputs: the zk flavour only, a keccak
transcript, bb 0.84 rather than a later one, and the verification key hash taken
from `session.getVkHash` rather than computed locally. `prove.sh --zkverify`
enforces the version, and the leaf formula in `ZkVerifyRiskSurface.leafFor` is
tested against a statement zkVerify returned rather than against a
reimplementation.

## Files

| | |
| --- | --- |
| `account.mjs` | creates the zkVerify account, prints the address for the faucet |
| `submit.mjs` | submits the proof for verification |
| `publish.mjs` | publishes the aggregation, writes the Merkle path |
| `domain.mjs` | registers a domain and submits to it |
| `collect.mjs` | polls for an aggregation receipt |
| `../../contracts/src/ZkVerifyRiskSurface.sol` | the consumer contract |
| `../../contracts/test/ZkVerify.t.sol` | eleven tests, one against the live contract |
