# zkVerify

The registry verifies an UltraHonk proof on Horizen directly. This folder is the
other road: the proof is verified once on zkVerify, batched into a Merkle tree,
and the root of that tree relayed to an EVM chain, where a contract admits the
surface on an inclusion check rather than a pairing check.

We built it rather than reasoning about it, because the trade-off is not obvious
until it is measured and because the integration has three traps that cost a day
between them.

## What actually happened

zkVerify verified our risk-surface proof and published the aggregation. Real
transactions on Volta, not a rehearsal:

| | |
| --- | --- |
| Submission | `0x49ed9bbc09931f5043cef404536e73b24aab5405d70a1aa38daa82feb2d96ba0` |
| Statement, the leaf zkVerify hashed | `0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730` |
| Domain, aggregation | 10, 2 |
| Published at | `0x761aa9e3d50849d1d01fe39e21847091ab40feef72bfe29d3d8db48a9de2fe1f` |
| Aggregation root | `0xb2ee6f0eb55cd0a4452c30da159adcfda7e6c0f227a22cb30c39229416946564` |
| Merkle path | empty, a single-leaf tree at index 0 |

The surface behind that statement is the reference book: 22 positions, 4,760,000
USDC, valued at 1789500000.

## The three traps

**bb 0.87 is rejected. You need bb 0.84.** The pallet's `V0_84` variant is tied
to that serialisation. A proof from a later bb verifies locally, against its own
verification key, and is still refused on chain with `Provided data has not valid
proof`, which tells you nothing about why. The sizes differ, 15,712 bytes against
16,224, and that is the quickest way to tell them apart.

**The vk hash is not `keccak256(vk_bytes)`.** The pallet hashes
`VersionedVk::encode()`, the SCALE encoding of the versioned enum, which carries
a discriminant and a length prefix. Ours:

```
keccak256(raw vk bytes)   0x94631642cbaec1b06cc9aa3fee68e2c44561dd983c47aa2cdae89ab3a6c3794b
zkVerify's getVkHash      0x5da1b785ba7eb5ff008935ce60182447b79a4d171b1b1f1f0722e5e8fc7c9b78
```

Take it from `session.getVkHash` rather than computing it.

**The statement has four components, not the three the documentation
describes.** Between the vk hash and the public inputs sits a
`verifier_version_hash`, `sha256("ultrahonk:v0.84")`. Omitting it produces a leaf
that is in no tree anywhere, silently. From `pallets/verifiers/src/lib.rs`:

```rust
let mut data_to_hash = keccak_256(ctx).to_vec();          // keccak256(b"ultrahonk")
data_to_hash.extend_from_slice(vk_hash.as_bytes());        // keccak256(SCALE(vk))
data_to_hash.extend_from_slice(version_hash.as_bytes());   // sha256("ultrahonk:v0.84")
data_to_hash.extend_from_slice(keccak_256(pubs).as_ref()); // keccak256(pubs, concatenated)
H256(keccak_256(&data_to_hash))
```

`ZkVerifyRiskSurface.leafFor` implements exactly that, and
`test_LeafReproducesTheStatementZkVerifyReturned` checks it against the statement
zkVerify returned above rather than against the documentation. Two further tests
show that the documented three-part formula and the naive vk hash both produce
something else.

One smaller detail while we were here: the root of a single-leaf tree is
`keccak256(leaf)`, not the leaf.

## What it costs, measured

| | Gas |
| --- | ---: |
| Verify the proof directly on Horizen | **2,364,745** |
| Admit the same surface from an aggregation | **237,846** |
| of which the leaf computation | 3,286 |

The second figure is mostly storage. Both routes write the same thirteen words of
risk surface, so the comparison that matters is the verification component alone:
**a pairing check over a 2^18 circuit against a Merkle path, roughly 2.1 M gas
against a few thousand.**

An order of magnitude is real. On Horizen at 0.001 gwei it is also the difference
between two thirds of a cent and a tenth of one, which is why Phase 1 verifies
directly and treats this as the option it is. On a chain with L1 gas prices the
arithmetic reverses, and the same consumer contract works there unchanged.

## The last mile, and the wall we hit

The aggregation exists on zkVerify. Getting its root onto an EVM chain is not
something an application can do for itself, and that is the finding rather than a
missing deposit.

A zkVerify domain carries a `delivery` field with a destination. Reading the
runtime metadata on both networks:

```
Volta (testnet)    : hp_dispatch::Destination = None
zkVerify (mainnet) : hp_dispatch::Destination = None
```

One variant, and it is None. No domain setting relays anywhere. Roots reach EVM
chains through a relayer zkVerify operates. We had started registering our own
domain to configure delivery, and stopped when the metadata said there was
nothing to configure. Domain deposits on Volta, read off existing owners' holds,
run 4.6 to 35.25 tVFY against a faucet paying 0.5, so this would have been an
expensive way to learn it.

What we did instead, on Base Sepolia, is copy the real root across by hand into a
stand-in and run everything downstream of it for real. See
[`../../deployment/base-sepolia.md`](../../deployment/base-sepolia.md):

- the consumer computes the leaf **on Base Sepolia** and it equals the statement
  zkVerify hashed on Volta, `0x0f3c234e…`, derived from nothing but the public
  inputs and the bound verification key
- the surface is admitted against the real root in 266,041 gas, transaction
  `0x5a88bdb5…`
- the second deployment, pointed at zkVerify's real contract instead, reverts
  with `NotAggregated`, because our aggregation genuinely is not relayed there

And on Horizen L3 the question does not arise: there is no aggregation contract
there at all, which is the finding that keeps this route off the Phase 1 critical
path.

## Running it

```sh
cd .. && ./prove.sh --zkverify     # zk-flavour proof, vk and hex, built with bb 0.84
cd zkverify && npm i

node account.mjs                   # creates .env, prints the address for the faucet
node submit.mjs                    # verifies the proof on zkVerify
DOMAIN_ID=10 AGGREGATION_ID=n STATEMENT=0x... node publish.mjs
                                   # publishes the aggregation, writes aggregation.json
```

`domain.mjs` registers a domain of your own and submits to it in one go, if you
have the deposit. `collect.mjs` polls for a receipt on a domain that aggregates
on its own schedule.

## Files

| | |
| --- | --- |
| `account.mjs` | creates the zkVerify account, prints the address for the faucet |
| `submit.mjs` | submits the proof for verification |
| `publish.mjs` | publishes the aggregation, writes the Merkle path |
| `domain.mjs` | registers a domain and submits to it |
| `collect.mjs` | polls for an aggregation receipt |
| `../book_attest/target/zkv084/` | the zk-flavour artefacts, built by `prove.sh --zkverify` |
| `../../contracts/src/ZkVerifyRiskSurface.sol` | the consumer contract |
| `../../contracts/test/ZkVerify.t.sol` | eleven tests, one against the live contract |
| `../../deployment/base-sepolia.sh` | deploys the consumer on Base Sepolia and admits a surface |
