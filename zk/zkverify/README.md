# zkVerify

The registry verifies an UltraHonk proof on Horizen directly. This folder is the
other road: the proof is verified once on zkVerify, batched with unrelated proofs
into a Merkle tree, and the root of that tree is relayed to an EVM chain. A
contract there then admits the surface on a Merkle inclusion check rather than a
pairing check.

We built it because it is the honest comparison to make before setting zkVerify
aside, and because the trade-off is not obvious until it is measured.

## What we established

**zkVerify accepts our proofs unchanged.** The UltraHonk pallet verifies proofs
from Noir's Barretenberg backend, which is what `book_attest` already produces.
Two constraints apply and both are met: only the **zk flavour** is accepted, so
the artefacts here are built with `bb prove --zk`, and only a **keccak
transcript**, which the circuit already uses.

**The aggregation contract is live on Base Sepolia and speaks the interface we
target.** `0x312468EbF274F1f584d93d0CCA8458cC91460FC0`, 17,826 bytes of code.
`test_LiveZkVerifyContractSpeaksOurInterface` calls it on a fork of Base Sepolia,
not a mock, and confirms `verifyProofAggregation` answers and refuses an
aggregation that was never posted.

**It is not deployed on Horizen L3.** That is the finding that keeps it off the
Phase 1 critical path. A Horizen contract cannot consume a zkVerify aggregation
today, because there is no aggregation contract on Horizen and no relayer route
to it. This is a deployment gap in a product Horizen Labs owns rather than a
technical one.

## What it costs, measured

| | Gas |
| --- | ---: |
| Verify the proof directly on Horizen | **2,364,745** |
| Admit the same surface from a zkVerify aggregation | **237,795** |
| of which the leaf computation | 3,286 |

The second figure is mostly storage. Both routes write the same thirteen words of
risk surface, so the comparison that matters is the verification component alone:
**a pairing check over a 2^18 circuit against a Merkle path, roughly 2.1 M gas
against a few thousand.** The zkVerify number also excludes zkVerify's own Merkle
check, a few keccaks per tree level.

An order of magnitude is real. It is also, on Horizen at 0.001 gwei, the
difference between two thirds of a cent and a tenth of one, which is why Phase 1
takes the direct road and treats this as the option it is. On a chain with L1 gas
prices the arithmetic reverses.

## The leaf

zkVerify hashes a statement rather than storing the proof. For UltraHonk:

```
leaf = keccak256(
    keccak256("ultrahonk"),      // proving system context
    keccak256(SCALE(vk)),        // the V0_84 vk hash
    keccak256(publicInputs)      // our 17 field elements, in circuit order
)
```

`ZkVerifyRiskSurface.leafFor` implements exactly that, and
`test_TamperingWithAPublishedNumberChangesTheLeaf` confirms that wiping the
90-plus delinquency bucket moves the leaf, so a surface cannot be edited after
zkVerify has attested to it.

## Running it

```sh
cd ../ && ./prove.sh --zkverify     # build the zk-flavour proof, vk and hex
cd zkverify && npm i

node account.mjs                    # creates .env, prints the address
                                    # faucet: https://zkverify-faucet.zkverify.io
                                    # email + address, tVFY within 24 hours

node submit.mjs                     # submits, waits for aggregation, writes
                                    # aggregation.json
```

`aggregation.json` carries the aggregation id, the Merkle path, the leaf count
and the index. Those are the arguments to `ZkVerifyRiskSurface.admit` on whatever
EVM chain the aggregation was relayed to.

## What is not done

The live submission has not run. The faucet asks for an email address and
delivers within 24 hours, which is not something a build script can wait on. The
account is created and the artefacts are built, so the submission is one command
away from an account that holds tVFY.

Everything up to that point is verified: the proof is the zk flavour zkVerify
requires, it verifies against its own verification key locally, the leaf formula
is tested, and the contract we would call has been probed live on Base Sepolia.

## Files

| | |
| --- | --- |
| `account.mjs` | creates the zkVerify account, prints the address for the faucet |
| `submit.mjs` | submits the proof, collects the aggregation and its Merkle path |
| `../book_attest/target/zkv/` | the zk-flavour proof, vk and hex, built by `prove.sh --zkverify` |
| `../../contracts/src/ZkVerifyRiskSurface.sol` | the consumer contract |
| `../../contracts/test/ZkVerify.t.sol` | six tests, one of them against the live contract |
