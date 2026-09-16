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

---

## The evidence behind the paper

| Folder | What is in it | What it backs |
| --- | --- | --- |
| [`zk/`](zk/) | Two Noir circuits, the scenario generator, the proving script | The risk surface is proven against a committed book, and a revision is proven to descend honestly from the one before it |
| [`tee/`](tee/) | The Vela stack we ran locally and the five findings it produced | Why Vela is our Phase 2 and not our Phase 1 |
| [`contracts/`](contracts/) | Registry, vault, `IRiskSurface`, both verifiers, thirty tests | The design survives being attacked, including by us |
| [`deployment/`](deployment/) | Live testnet addresses, scripts, every transaction hash | It runs on Horizen, and the chain refuses what we say it refuses |
| [`architecture/`](architecture/) | Source of the paper, rebuild with `./build.sh` | |
| [`FEASIBILITY.md`](FEASIBILITY.md) | Horizen measured rather than read, with what is live and what is not | |

### Check it without us

All five contracts are source-verified on the Horizen testnet explorer, chain
2651420, so the code running at these addresses can be read rather than trusted.

| | |
| --- | --- |
| Registry | [`0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B`](https://horizen-testnet.explorer.caldera.xyz/address/0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B) |
| Vault | [`0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651`](https://horizen-testnet.explorer.caldera.xyz/address/0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651) |

```sh
./deployment/read-state.sh    # reads only, no keys, no trust in us
```

Three readings show the mechanism working:

```
scheduledFor(0)       33,487.50 USDC    written once, before the period began
realizedFor(0)        12,000.00 USDC    only moves when tokens actually arrive
performanceRatio(0)       35.83 %       computed from the two, by nobody
```

Read that for what it is. Both figures come from us: the 33,487.50 is the
monthly interest on a book we generated in [`zk/gen.py`](zk/gen.py), and the
12,000 is a payment we chose to make short so the shortfall would be visible.
We authored both sides of the fraction.

What the chain enforces, and we cannot: `scheduled` is written once when the
surface is published and can never be revised afterwards, `realized` only moves
on a token transfer that actually settles, and the ratio is derived from the two
with no one in the loop. The detector is real and was tested. The fire was lit
by us.
