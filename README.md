# Agama x Horizen

**Builder Ecosystem Fund application. Category 1, private borrow-lend protocol.**

Confidential private credit on Horizen, where the loan book stays private and
the credit risk does not.

---

## The paper

### → [`Agama x Horizen - Technical Architecture.pdf`](Agama%20x%20Horizen%20-%20Technical%20Architecture.pdf)

Twenty pages. Read that first. Everything else in this repository exists so you
can check a claim in it without taking our word for anything.

---

## What this application answers

Your review of our first submission contained the sentence that reshaped the
design:

> "If the issuer signs a clean book and the loans are already bad, the TEE and
> the ZK proof still pass."

That is correct, and no amount of additional cryptography changes it. A trusted
execution environment attests that code ran on data. A proof attests that
numbers follow from a commitment. Neither one reaches the world.

So we stopped trying to prevent the lie and made it **falsifiable in public, on
a fixed clock, without naming a single borrower**.

| Your observation | What changed |
| --- | --- |
| The depositor cannot see maturities or terms | Position count, principal, maturity ladder, delinquency buckets and concentration are published on every attestation, proven against an on-chain commitment. Borrower identity stays private, and we will defend that. |
| Public is NAV and vault size, so you check arithmetic and not credit | NAV is computed from the proven surface and a public impairment schedule fixed at deployment. The originator has no discretion over its own mark. |
| A clean signature over a bad book still passes | It still does. The book then misses the cash calendar it published **before** the period began. Repayments arrive on-chain, so the shortfall is arithmetic on two numbers, one of which the originator committed to before it knew the answer. |
| Weekly redemptions, so the depositor is last to see a run | Weekly gates are gone. The queue is public state and settles at one pro-rata ratio for everyone, so queueing early buys nothing and there is no race to start. |
| Not a primitive you can diligence on-chain | `IRiskSurface` is a public MIT interface with no Agama dependency, so a Horizen lending market can set an LTV on vault shares programmatically. |
| Not live mainnet, a testnet vault plus a Vela plan | Vela is off the critical path, for reasons in [`tee/`](tee/). The stack is deployed and the evidence is below. |

Point by point, at length: [`RESPONSE.md`](RESPONSE.md).

---

## The evidence behind the paper

| Folder | What is in it | What it backs |
| --- | --- | --- |
| [`zk/`](zk/) | Two Noir circuits, the scenario generator, the proving script | The risk surface is proven against a committed book, and a revision is proven to descend honestly from the one before it |
| [`tee/`](tee/) | The Vela stack we ran locally and the five findings it produced | Why Vela is our Phase 2 and not our Phase 1 |
| [`contracts/`](contracts/) | Registry, vault, `IRiskSurface`, both verifiers, thirty tests | The design survives being attacked, including by us |
| [`deployment/`](deployment/) | Live testnet addresses, scripts, every transaction hash | It runs on Horizen, and the chain refuses what we say it refuses |
| [`architecture/`](architecture/) | Source of the paper, rebuild with `./build.sh` | |
| [`FEASIBILITY.md`](FEASIBILITY.md) | Horizen measured rather than read | |

### Check it without us

All five contracts are source-verified on the Horizen testnet explorer, chain
2651420, so the code running at these addresses can be read rather than trusted.

| | |
| --- | --- |
| Registry | [`0x034635c324d83D590691C68d711AA5FA2FbA084f`](https://horizen-testnet.explorer.caldera.xyz/address/0x034635c324d83D590691C68d711AA5FA2FbA084f) |
| Vault | [`0x58b90F2aA6C48B19B8792Bf4a5dcd2437Ae8FfA9`](https://horizen-testnet.explorer.caldera.xyz/address/0x58b90F2aA6C48B19B8792Bf4a5dcd2437Ae8FfA9) |

```sh
./deployment/read-state.sh    # reads only, no keys, no trust in us
```

Three readings are the whole argument:

```
scheduledFor(0)       33,487.50 USDC    published before the period began
realizedFor(0)        12,000.00 USDC    cash observed on-chain, not reported
performanceRatio(0)       35.83 %       a number nobody had to agree to
```

---

## What we are asking the fund to pay for

The architecture is de-risked, not finished.

| | Deliverable | Acceptance |
| --- | --- | --- |
| **M1** | The stack on Horizen **mainnet** with a real originator book, and a public dashboard reading the risk surface straight from the registry | Contracts verified on the mainnet explorer. One committed book, one proven surface, one epoch of realised collections, all readable on-chain by a third party. |
| **M2** | Security audit of registry, vault and both circuits. Recursive aggregation so a book is not capped at 64 positions per batch. | Audit report published. A book of several hundred positions attested in one surface. |
| **M3** | Live book with real capital, continuous attestation, and a second originator adopting `IRiskSurface` independently of Agama | Principal outstanding, uninterrupted attestation cadence, and at least one non-Agama implementation of the interface on Horizen. |

The M3 criterion is deliberately one we do not fully control. A disclosure
standard that only its author uses is not a primitive, and you should hold us
to that.

---

## What we are not claiming

**The book behind every figure here is synthetic**, generated by
[`zk/gen.py`](zk/gen.py). There is no real originator, no real borrower and no
real collection behind the testnet numbers. What is demonstrated is that the
machinery works and refuses what it says it refuses. Putting a real book behind
it is M1, and it is what we are asking you to fund.

We also cannot make a depositor able to underwrite this credit, and we will not
pretend otherwise. Someone with full access still has to do that work. Our claim
is narrower: the depositor can verify the risk shape, watch performance as a
falsifiable series on a clock the originator committed to in advance, see that
an independent party with full access is reviewing the book on a fixed cadence,
exit through a public queue with no first-mover advantage, and know that the
originator loses first.

That is the side letter, moved on-chain, where a contract can read it.
