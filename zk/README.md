# Zero knowledge

Two [Noir](https://noir-lang.org/) circuits, proven with Barretenberg
UltraHonk and verified on-chain by Horizen.

| Circuit | Proves | Size | Prove | Verify on Horizen |
| --- | --- | --- | --- | --- |
| [`book_attest`](book_attest/) | The published risk surface really is the surface of the book committed at this root: count, principal, maturity ladder, delinquency buckets, concentration, and the cash contractually owed over the next 30 days | 66,067 ACIR opcodes | 3.0 s | 2,364,745 gas |
| [`book_delta`](book_delta/) | A revision is the previous book plus permitted operations only, and nothing else | 6,906 ACIR opcodes | 1.2 s | 2,222,133 gas |

`book_delta` exists because our own first draft had a hole in it. A revision
published a new root and nothing proved the new book descended from the old
one, so an originator could have inserted an already-defaulted position with a
backdated origination date. The circuit closes it: a position holds a
permanent slot for the life of the book, a carried position may not change
obligor, maturity or origination date, principal may only amortise down, the
payment date may only move forward, and a new position may only enter an empty
slot with an origination date at or after the moment the previous root reached
the chain, a timestamp the registry supplies from its own storage rather than
accepting from the originator.

## Build

```sh
./prove.sh              # proofs, the attack, and both Solidity verifiers
./prove.sh --quick      # skip regenerating the verifiers
./prove.sh --zkverify   # also build what zkVerify needs, see zkverify/
```

Needs `nargo` and `bb` on the path. The `--zkverify` flag additionally needs
bb 0.84 at `$HOME/.bb/bb-0.84`, because zkVerify's UltraHonk verifier pins
that version.

**The build runs the attack every time.** It constructs a defaulted 900,000
USDC position, drops it into a free slot dated 200 days early, and tries to
prove the revision. Witness generation fails with `new position backdated`,
and a proof that succeeds is treated as a build failure rather than a result.

## Two things a reviewer can reproduce exactly

**The deployed verifiers.** `./prove.sh` regenerates `HonkVerifier.sol` and
`DeltaVerifier.sol` byte for byte identical to the files committed here, which
are the contracts deployed and source-verified on Horizen testnet at
`0xb95B360324edbfd324e19196F6fF3B97E9EaA7dA` and
`0xA3C1e81Fdadb5bd098546A4B8FBDfe4169436cF4`. That is a complete chain from
circuit source to on-chain bytecode, and `git status` staying clean after a
build is the check.

**The test fixtures.** With no environment set, [`gen.py`](gen.py) is fully
deterministic at `AGAMA_AS_OF_0 = 1789500000`, and produces exactly the proofs
and public inputs in `../contracts/test/fixtures/` that the Foundry suite
consumes. The t0 book root is
`0x218147fcdc4d96547a204a0fb4b46442f7ff5f2d3811de010e750dc52e3e24e4`.

## Why the roots on-chain are different ones

The root published on Horizen testnet is
`0x0953637ea6121b0789a1e47f6c6112fa265bef67f3ccd8cead5c69a914976a21`, not the
fixture root, and that is the design rather than a mismatch.

A book root binds its valuation date. The registry will not accept a surface
whose valuation date is in the future, and will not accept one that predates
the commitment of its own root, so a live run has to pick a date, commit the
root while that date is still ahead, wait for it to arrive, and only then
publish. That is the commit-before-outcome property the whole disclosure
argument rests on, and it means the live run's roots are a function of the
wall clock at the moment it ran.

`gen.py` takes those dates from `AGAMA_AS_OF_0`, `AGAMA_AS_OF_1` and
`AGAMA_PREV_COMMIT`, which is how [`../deployment/live-testnet.sh`](../deployment/live-testnet.sh)
drives it. Two of the three are readable back off the chain,
`bookCommittedAt(root)` and the revision's valuation date, but the first run's
valuation date was never written down, so those specific roots cannot be
regenerated after the fact. Later runs record all three in the deployment
JSON.

What this does not weaken: the proof behind the on-chain surface verified
against the committed root, in the verifier contract, in a transaction anyone
can open. Reproducing the witness is a convenience. Verifying the proof is the
guarantee, and that already happened on Horizen.

## zkVerify

[`zkverify/`](zkverify/) is the optional route: the same proof verified and
aggregated on zkVerify's Volta testnet, with a consumer on Base Sepolia that
recomputes zkVerify's statement on-chain and admits the surface for 266,041
gas against 2,364,745 direct.
