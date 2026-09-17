# Act two: independent verification, a real queue, and refusals on-chain

Same deployment as `deployment-testnet.md`. Registry `0x658A4745c517daa9FA7e221506e5d3f7a352554F`,
vault `0xa5Af4F297fF72855e778E70701de7f1dd6B8bEc0`, chain 2651420.

Every row below is a mined transaction. The refusals are not test assertions:
they are transactions the chain executed and reverted, and each one has a hash
you can open.

| Call | Transaction | Outcome | Gas |
| --- | --- | --- | --- |
| `attest` | [`0xc44d7a30cd98dfcb…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xc44d7a30cd98dfcbe6c4d6bad453ed8d20f85ec10cd3a9b11dd6612fee7daae6) | succeeded | 140363 |
| `fund LP1 gas` | [`0x54864371c4d10c36…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x54864371c4d10c36e154c5c6dc9ebdcbd6ebc571ede958bf769956c75c6782c7) | succeeded | 21000 |
| `LP1 mint` | [`0x86d82040cf9db86b…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x86d82040cf9db86bef03f3fdc9a69ddc778d2ce6bce145dfe54c461a7f0c10eb) | succeeded | 51291 |
| `LP1 approve` | [`0xd531006eccc079a6…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xd531006eccc079a6606ae168d8ce9488cca70f21e6343833527d6748ab2feaa8) | succeeded | 46342 |
| `LP1 deposit` | [`0x373825003b1a7989…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x373825003b1a79892b431e48dbc570b7337f467aedf16a97c1f40fb63e18618c) | succeeded | 105925 |
| `fund LP2 gas` | [`0x23f6f32f26f94fa3…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x23f6f32f26f94fa31471c3dcc04cb7ea1f00ce584b7e42a4d0dcc159678cfb19) | succeeded | 21000 |
| `LP2 mint` | [`0xa3f9ea1d7ef36597…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xa3f9ea1d7ef36597342a6f32b898952062695496fdf1699d9e7837d17f94397a) | succeeded | 51279 |
| `LP2 approve` | [`0x7382b76c3a03b1f5…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x7382b76c3a03b1f5de655e740d01132e254dfa10a2dcc4e6d70d54f81074ce57) | succeeded | 46342 |
| `LP2 deposit` | [`0xd70a3726bf07404c…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xd70a3726bf07404cd7cf9312ef95e12714bc44e79ec1bf31e5376008cbc6186b) | succeeded | 105913 |
| `fund LP3 gas` | [`0x435612db082bcdad…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x435612db082bcdada0e7818a9118187f32471ac43d43090001a01fc1b4d62608) | succeeded | 21000 |
| `LP3 mint` | [`0xedb2b9cf4af132ec…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xedb2b9cf4af132ec1dbf34d3530bc1fbf02350e43eceb96e2840287797dca384) | succeeded | 51291 |
| `LP3 approve` | [`0xfa8f7f15e1efaec8…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xfa8f7f15e1efaec83c14e2195edf9df253ac58953d43379dbab4468fea2744f3) | succeeded | 46342 |
| `LP3 deposit` | [`0xe2277260e8a7c2a1…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xe2277260e8a7c2a1eea829d8810917c4fc162fa67aaa8089833217b559870cf3) | succeeded | 105925 |
| `LP1 requestRedeem` | [`0xbbc9f42f4c20a1b1…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xbbc9f42f4c20a1b1c76bb2f11c452bc0dcfd28bda30246caf4e91d7427ef917b) | succeeded | 142838 |
| `LP2 requestRedeem` | [`0xd6b3f71dc3188506…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xd6b3f71dc318850606574ceee8f511a28b42597871530f46582fdd744199ed0a) | succeeded | 142838 |
| `LP3 requestRedeem` | [`0x4a6d7a29bc0fe30f…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x4a6d7a29bc0fe30fed4d49384cdc5ef5fd57904e633f061f1c3bd44af094cde9) | succeeded | 142838 |
| `settle` | [`0x3e7012579e536570…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x3e7012579e536570b71693c1022627da24a0e52180c1bf26dfc1e2506b6d2444) | succeeded | 297258 |

## Fill ratios in the settlement above

| Party | Asked, USDC | Received, USDC | Fill |
| --- | ---: | ---: | ---: |
| LP1, queued last | 100000.00 | 22988.51 | 22.989% |
| LP2, queued last | 200000.00 | 45977.01 | 22.989% |
| LP3, queued last | 300000.00 | 68965.52 | 22.989% |
| Founding LP, queued first | 2010000.00 | 462068.97 | 22.989% |


## Attacks submitted to the chain, and refused by it

| Attack | Transaction | What actually stopped it |
| --- | --- | --- |
| Understate the 90-plus delinquency bucket | [`0xda30503e6fbb8631…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xda30503e6fbb8631235e6e94915100d80394b784ca5b10242743ada57a59232d) | **SumcheckFailed(), inside the verifier** |
| The same tampered inputs, carrying an older valuation date | [`0x3b5e3c9b0f610b10…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x3b5e3c9b0f610b10777957f977fc269c84fddaad6735e744a9597b4216f1b877) | **SurfaceNotMonotonic()** |
| Re-publish a stale surface to restore a flattering impairment | [`0x4f159e6182df10c9…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x4f159e6182df10c94daa73ed7ae76f3a427baf773d2c49f536329e4bc09aa84e) | **SurfaceNotMonotonic()** |
| Claim a false previous-commitment date, from the current root | [`0x2ab4bc105d6bbbd1…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x2ab4bc105d6bbbd1635fec1bdc5abdab67e10276477918dfd503fb009fccf2e9) | **WrongCommitTimestamp()** |
| The same lie, told from a superseded root | [`0x6f290139b070727a…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x6f290139b070727a70145ef1b32125ce9165f7260aa9361cc2671420d03bf08b) | **NotDescendedFromLatest()** |
| Replay the revision to fork history off an old root | [`0xbb3a212e79c87bca…`](https://horizen-testnet.explorer.caldera.xyz/tx/0xbb3a212e79c87bcac84d67d316629eb2b75fdad5452dd88bff22f95b789ac7e5) | **NotDescendedFromLatest()** |
| Declare a second genesis book | [`0x207c7aba4d1d5480…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x207c7aba4d1d5480c9cb31e6ba86e3ab61def74e7e33c4e6b112e5ca7a28e32c) | **GenesisAlreadySet()** |
| Raise the disbursement ceiling without moving cash | [`0x81d9348cf3284719…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x81d9348cf3284719d0e49cef7154860960987d62a0ba250843320e6aab5349eb) | **NotVault()** |
| Disburse from the vault without the role | [`0x248a2cba2922efbd…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x248a2cba2922efbd68a100091fea97061176f37e18ec18aca5268e32ceeceee4) | **AccessControlUnauthorizedAccount()** |
| Jump the queue through `redeem` | [`0x244daf5478cf3a8e…`](https://horizen-testnet.explorer.caldera.xyz/tx/0x244daf5478cf3a8e5499d3b5ea05b799e94714e01fc8af0f6a30ba771a2dd225) | **ERC4626ExceededMaxRedeem()** |

**On the two pairs above.** The registry checks in increasing cost order, so an
attack aimed at an expensive guard is often answered by a cheaper one first.
Rather than credit a refusal to a mechanism that never ran, each pair is
submitted twice: once shaped to reach the guard it is aimed at, and once as it
would naturally arrive, showing which guard actually answers. The reason in the
last column is read back off the chain by replaying the call at the block before
it was mined, not asserted by the script.

## State after act two

| Reading | Value | What it means |
| --- | ---: | --- |
| `attestationCount()` | 1 | independent parties that have recorded a look |
| `bookHistoryLength()` | 2 | genesis plus one proven revision |
| `impairedPrincipal()` | 246,500.00 USDC | mechanical, from the fixed schedule |
| `carryingValue()` | 4,513,500.00 USDC | principal net of impairment |
| `performanceRatio(0)` | 35.834 % | realised against the calendar published first |
| `totalAssets()` | 4,760,000.00 USDC | NAV, first-loss absorbing the impairment |
| `firstLossRemaining()` | 253,500.00 USDC | junior capital still standing |
| `queueDepth()` | 4 | tickets still open after the settlement |
| `coverageRatio()` | 11.1 % | 30-day cash against what the queue is owed |

All of it readable with `./read-state.sh`, which makes eth_call reads only.
