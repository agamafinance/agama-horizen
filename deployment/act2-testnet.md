# Act two: independent verification, a real queue, and refusals on-chain

Same deployment as `deployment-testnet.md`. Registry `0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B`,
vault `0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651`, chain 2651420.

Every row below is a mined transaction. The refusals are not test assertions:
they are transactions the chain executed and reverted, and each one has a hash
you can open.

| Call | Transaction | Outcome | Gas |
| --- | --- | --- | --- |
| `attest` | [`0x24baa07a8f223901…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x24baa07a8f22390100d99150bc03324e497e2cc9adf2fe440d26ed0d4ba4d0c8) | succeeded | 140363 |
| `fund LP1 gas` | [`0x377d6df16fd54db8…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x377d6df16fd54db8a960fd386e2d546c287bfb4e42681c144a3472cd0a961a1c) | succeeded | 21000 |
| `LP1 mint` | [`0xe5b3fba38644111c…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xe5b3fba38644111cd0bdf0d2769d18183ea4c038f48e4a36b29e8134610cfa8b) | succeeded | 51291 |
| `LP1 approve` | [`0x1be11dc5fffceb40…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x1be11dc5fffceb4049aa9b4a2565a2491a0f287701d3468ca41fcfd9f08c3814) | succeeded | 46342 |
| `LP1 deposit` | [`0xc15681ad6df71ca9…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xc15681ad6df71ca9c82a9c4d9badea349f0e6c512e809905b364b9b875908e3e) | succeeded | 105925 |
| `fund LP2 gas` | [`0x343ecf9081fe9760…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x343ecf9081fe976001b49c873a90f4ac970422a7f627dd1302487bf09f30b096) | succeeded | 21000 |
| `LP2 mint` | [`0x34bbbcf71422a2ce…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x34bbbcf71422a2ced14a666304e0b871a52a5db92bebea66769a57ef4923c1f3) | succeeded | 51279 |
| `LP2 approve` | [`0x9807ebf7f40d2a18…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x9807ebf7f40d2a18fefa060c5d01a8b45ccc8f6a297711bc23369f546f1c0019) | succeeded | 46342 |
| `LP2 deposit` | [`0x72bf5eb993dc7c34…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x72bf5eb993dc7c349f0a853258290cab8c94cae94cf738ff8848dc57c13636ff) | succeeded | 105913 |
| `fund LP3 gas` | [`0xb0957fae62b95db4…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xb0957fae62b95db4bf83b5be76a5e0f266a45329d25de54671f2c0f7b73e6eb2) | succeeded | 21000 |
| `LP3 mint` | [`0xcaf30621c8a0ab31…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xcaf30621c8a0ab31247d1ae933095477f145e2de1910926f8eb76fb19795462f) | succeeded | 51291 |
| `LP3 approve` | [`0x37a0b85ac60ac032…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x37a0b85ac60ac032f50ee01ef185f26738812146cfeb91abb1c6bf776ebe51cc) | succeeded | 46342 |
| `LP3 deposit` | [`0xad13379e140f7635…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xad13379e140f76354f938cd491f9e3e928f08ee0e2bb62dde04d06843c6b1f2f) | succeeded | 105925 |
| `LP1 requestRedeem` | [`0x737ae41e76fd3d6d…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x737ae41e76fd3d6d7ddd014a7a916e75b01c3d44efca5a096cc40e656ac09d94) | succeeded | 140537 |
| `LP2 requestRedeem` | [`0x4e6aa87de2041148…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x4e6aa87de20411481c0544d0ee6f6f356de360b0307e88ae3668d1c842c54d5a) | succeeded | 140537 |
| `LP3 requestRedeem` | [`0x71ce909a0481829f…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x71ce909a0481829f8d08d740f6f2f8152d9b9d47a63c10147f465addef85ae97) | succeeded | 140537 |
| `settle` | [`0x5c5f3e55af8bf68f…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x5c5f3e55af8bf68f7b9dbbe4268b3f09f2031da421f09f8aa11590b17ab5461a) | succeeded | 297258 |

## Fill ratios in the settlement above

| Party | Asked, USDC | Received, USDC | Fill |
| --- | ---: | ---: | ---: |
| LP1, queued last | 100000.00 | 22988.51 | 22.989% |
| LP2, queued last | 200000.00 | 45977.01 | 22.989% |
| LP3, queued last | 300000.00 | 68965.52 | 22.989% |
| Founding LP, queued first | 2010000.00 | 462068.97 | 22.989% |

## Attacks submitted to the chain, and refused by it

These are **mined transactions that reverted**, not test assertions. Each one has
a hash anyone can open. The reason column is the revert selector recovered by
replaying the call at the block before it was mined.

| Attack | Transaction | What actually stopped it |
| --- | --- | --- |
| Understate the 90-plus delinquency bucket | [`0x9d47556cf9c0ce51…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x9d47556cf9c0ce51525fc9cd8e9f3cdc801bf37005720e4e5548cb201b83af94) | Reverted **inside the verifier**, selector `0x05b6e6bf`. The proof does not survive its public inputs being edited. |
| Re-publish a stale surface to restore a flattering impairment | [`0x8a0ffd1d35d57e9c…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x8a0ffd1d35d57e9c3d42140d3ade7c9fd0adba2d309f838b1a613eafbec0e027) | `SurfaceNotMonotonic()` |
| The same tampered inputs, carrying an older valuation date | [`0x3692a8f51882136a…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x3692a8f51882136a279a64da5c54f2ac49eae8734142ab0d5eef0d28a43a57e0) | `SurfaceNotMonotonic()`, before the proof was examined. See the note below. |
| Replay the revision to fork history off an old root | [`0x93844d302f2e1c4b…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x93844d302f2e1c4b653e3271bd5b7e9d9d3679a578316dea2251391c114b3b8d) | `NotDescendedFromLatest()` |
| Claim a false previous-commitment date, from the current root | [`0x20b81218fa26edb1…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x20b81218fa26edb170ff2cab50fa1d0840a05d37ba32c25b2ae19cb630ba1d5a) | `WrongCommitTimestamp()` |
| The same lie, from a superseded root | [`0xbfa57775aa1a5b6f…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xbfa57775aa1a5b6f5a4ade2a15126d0d209cb39d77cd90e55172f0b9a3919199) | `NotDescendedFromLatest()`, before the date was examined. |
| Declare a second genesis book | [`0xc5fe10fba2cab01b…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xc5fe10fba2cab01b149be14b21e97e35885d9a8e5089c167931a95196b520c86) | `GenesisAlreadySet()` |
| Raise the disbursement ceiling without moving cash | [`0x5a13d15073849b61…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x5a13d15073849b6145bf2ff5c5b683072e180f01a8e40410cdde8fc6c9e9708c) | `NotVault()` |
| Disburse from the vault without the role | [`0x8b75d59b62c62b08…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x8b75d59b62c62b08d9e7a2636c92cf410fb3cba79edd42b43d730810fa3c43aa) | `AccessControlUnauthorizedAccount` |
| Jump the queue through `redeem` | [`0x95973c8394c2b5b6…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x95973c8394c2b5b672c89ae22ceadb0eff4dc2fef643c4c945787261179919c1) | `ERC4626ExceededMaxRedeem` |

### A note on two of these, because the first labels we wrote were wrong

Two attacks were refused by a guard **earlier** than the one they were aiming at,
and our first version of this table named the wrong mechanism.

The registry checks in ascending order of cost: root committed, valuation date
sane, monotonic, descended from the latest root, commitment date matching the
chain, principal within what was disbursed, and only then the proof. A tampered
surface carrying an old valuation date never reaches the verifier because
monotonicity rejects it first, and a revision quoting the wrong parent never
reaches the timestamp check.

So we ran both again, shaped to pass the cheap guards and reach the intended one.
The first row does reach the verifier, which rejects it. The fifth descends from
the current root and does reach the timestamp check.

Ordering cheap checks first is the right design. Reporting a refusal as coming
from a mechanism that never ran is not, which is why both rows above now say what
actually happened.

## State after act two

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
is not a failure, it is the design being honest. The vault paid out everything it
had, pro-rata, and the remaining claims are on credit that has not matured. The
reserve floor now blocks any further disbursement until the book is back above it.
