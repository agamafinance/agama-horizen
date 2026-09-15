# Act two: independent verification, a real queue, and refusals on-chain

Same deployment as [`deployment-testnet.md`](deployment-testnet.md), on Horizen
testnet, chain 2651420.

- Registry `0x034635c324d83D590691C68d711AA5FA2FbA084f`
- Vault `0x58b90F2aA6C48B19B8792Bf4a5dcd2437Ae8FfA9`

All five contracts are **source-verified on the explorer**, so the code at those
addresses can be read without asking us for anything.

Reproduce with `deploy/act2-testnet.sh`.

---

## 1. The verification agent records that it looked

| Call | Transaction | Gas |
| --- | --- | ---: |
| `attest` | [`0x32de6bd4865c81d7…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x32de6bd4865c81d760dc3814330b4d37f2f053f7312bf30506a72a9f6fcadbd4) | 140,307 |

`attestationCount()` returns 1 and `verificationAge()` now counts up from that
transaction. A depositor cannot read the book. A depositor can read the fact
that someone with full access reviewed it, when, against which root, and what
they concluded, and can read the silence if the reviews stop.

## 2. Four parties in one queue, one ratio for everyone

Three new depositors joined, sized 100k, 200k and 300k USDC, and queued **after**
the founding depositor whose 2.01 M ticket had been waiting since the previous
settlement. Being first in line, by a wide margin, bought nothing:

| Party | Queue position | Asked, USDC | Received, USDC | Fill |
| --- | --- | ---: | ---: | ---: |
| Founding LP | **first**, and much earlier | 2,010,000.00 | 462,068.97 | **22.989 %** |
| LP1 | later | 100,000.00 | 22,988.51 | **22.989 %** |
| LP2 | later | 200,000.00 | 45,977.01 | **22.989 %** |
| LP3 | later | 300,000.00 | 68,965.52 | **22.989 %** |

Sizes span twenty to one. The fills are identical to three decimal places, and
the residual difference is integer rounding on a six-decimal asset, not an
ordering advantage. Settlement:
[`0x71ac1e2b20b3412e…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x71ac1e2b20b3412e9cd4d3fd628937f3fe538280a1580fc40ad9117a0389846a),
302,121 gas.

This is the claim in Section 6 of the architecture document, executed on a
public chain rather than asserted in a test.

## 3. Attacks submitted to the chain, and refused by it

These are **mined transactions that reverted**, not test assertions. Each one
has a hash anyone can open. The reason column is the revert selector recovered
by replaying the call at the block before it was mined.

| Attack | Transaction | What actually stopped it |
| --- | --- | --- |
| Understate the 90-plus delinquency bucket | [`0xd43220bf216c8e09…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xd43220bf216c8e09ead56e69c6ed40accbe9695012838c75c89c1d7741a56f00) | Reverted **inside the verifier**, selector `0x05b6e6bf`. The proof does not survive its public inputs being edited. |
| Re-publish a stale surface to restore a flattering impairment | [`0x45081dc1b696b8f2…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x45081dc1b696b8f29429250a94a777991f82a2b6b3cde8b65af8db4593de9794) | `SurfaceNotMonotonic()` |
| The same tampered inputs, carrying an older valuation date | [`0x59610233b28b6c4b…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x59610233b28b6c4b98bda0f87b5709a67a7001ebb5413e275d44c1bd052763bc) | `SurfaceNotMonotonic()`, before the proof was examined. See the note below. |
| Replay the revision to fork history off an old root | [`0xe34396a94ee36abb…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xe34396a94ee36abbefc62310b995a796c3c277fa1b8e3f3396470246f6ec745a) | `NotDescendedFromLatest()` |
| Claim a false previous-commitment date, from the current root | [`0xcad557d19dc9d7f3…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xcad557d19dc9d7f3129bb985ed71ab4f85d1438dea9d274b0760138d6e9bacfc) | `WrongCommitTimestamp()` |
| The same lie, from a superseded root | [`0x656849df06db956c…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x656849df06db956cb82b7ca40a2192ef39034bf78065b0b73291769ad4fcda6b) | `NotDescendedFromLatest()`, before the date was examined. |
| Declare a second genesis book | [`0xcb877071cb29569b…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xcb877071cb29569bf30fb5b8d06a51d9e4c4dfa09fe6c1dece99415f15ad84c6) | `GenesisAlreadySet()` |
| Raise the disbursement ceiling without moving cash | [`0xc0a02aa94ca31c87…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xc0a02aa94ca31c87cacb5dd516e1d5e68487115db2eee3d4b93959d3bb17342f) | `NotVault()` |
| Disburse from the vault without the role | [`0xb39db7f3e2dbc2c6…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xb39db7f3e2dbc2c6736c866de3df422297edac378a38f297f211649a071f5337) | `AccessControlUnauthorizedAccount` |
| Jump the queue through `redeem` | [`0x8a86e31249a02130…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x8a86e31249a02130f4557641be1696166dee795b04edb4330c861ee984fc2228) | `ERC4626ExceededMaxRedeem` |

### A note on two of these, because the first labels we wrote were wrong

Two attacks were refused by a guard **earlier** than the one they were aiming
at, and our first version of this table named the wrong mechanism.

The registry checks in ascending order of cost: root committed, valuation date
sane, monotonic, descended from the latest root, commitment date matches the
chain, principal within what was disbursed, and only then the proof. A tampered
surface carrying an old valuation date never reaches the verifier because
monotonicity rejects it first, and a revision quoting the wrong parent never
reaches the timestamp check.

So we ran both attacks again, shaped to pass the cheap guards and reach the
intended one. `0xd432…` carries a valuation date newer than the published
surface and does reach the verifier, which rejects it. `0xcad5…` descends from
the current root and does reach the timestamp check, which rejects it with
`WrongCommitTimestamp()`.

Ordering cheap checks first is the right design. Reporting a refusal as coming
from a mechanism that never ran is not, which is why both rows above now say
what actually happened.

## 4. State after act two

| Reading | Value |
| --- | --- |
| `attestationCount()` | 1 |
| `bookHistoryLength()` | 2 |
| `impairedPrincipal()` | 246,500 USDC |
| `carryingValue()` | 4,513,500 USDC |
| `performanceRatio(0)` | **35.83 %** |
| `firstLossRemaining()` | 253,500 of 500,000 USDC |
| `queueDepth()` | 4 |
| `buffer()` | drained to the unit by the settlement |

The buffer sitting at effectively zero while the queue still holds four tickets
is not a failure, it is the design being honest. The vault paid out everything
it had, pro-rata, and the remaining claims are on credit that has not matured.
`coverageRatio()` says so publicly, and the reserve floor now blocks any further
disbursement until the book is back above it.
