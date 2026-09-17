# Deployment

Everything that ran on a public chain, with the transaction hashes to check it.
Nothing here needs a key or any cooperation from us.

```sh
./read-state.sh    # reads only: eth_call against Horizen testnet
```

## Horizen testnet, chain 2651420

All five contracts are source-verified on
[the explorer](https://horizen-testnet.explorer.caldera.xyz), so the code
running at these addresses can be read rather than trusted.

| | |
| --- | --- |
| Registry | [`0x658A4745c517daa9FA7e221506e5d3f7a352554F`](https://horizen-testnet.explorer.caldera.xyz/address/0x658A4745c517daa9FA7e221506e5d3f7a352554F) |
| Vault | [`0xa5Af4F297fF72855e778E70701de7f1dd6B8bEc0`](https://horizen-testnet.explorer.caldera.xyz/address/0xa5Af4F297fF72855e778E70701de7f1dd6B8bEc0) |
| ZK verifier | [`0x50E753B8060028186d9E090461A9Ff8b6407d1A2`](https://horizen-testnet.explorer.caldera.xyz/address/0x50E753B8060028186d9E090461A9Ff8b6407d1A2) |
| Revision verifier | [`0x00127EFEfac82972E112D92298CfDB9C5E45A71C`](https://horizen-testnet.explorer.caldera.xyz/address/0x00127EFEfac82972E112D92298CfDB9C5E45A71C) |
| Test USDC | [`0xbfF7a3dE99131220bB301129c6F8049abec4c524`](https://horizen-testnet.explorer.caldera.xyz/address/0xbfF7a3dE99131220bB301129c6F8049abec4c524) |

| File | What it holds |
| --- | --- |
| [`deployment-testnet.md`](deployment-testnet.md) | The first act: deploy, commit the book before any cash moves, fund, disburse, prove, publish. Every hash |
| [`act2-testnet.md`](act2-testnet.md) | The second act: collections short of the published calendar, an honest revision, four parties settled pro-rata, and ten attacks mined as reverts |
| `live-testnet.sh`, `act2-testnet.sh` | The scripts that produced them. They need a funded key, which is why the reading above is a separate script that does not |
| `deployment-testnet.json` | Addresses, the genesis root, and the epoch genesis |

## Base Sepolia, chain 84532

The zkVerify route. See [`base-sepolia.md`](base-sepolia.md) and
[`../zk/zkverify/`](../zk/zkverify/) for how the aggregation was produced and
why the root had to be carried across by hand.

## Reading the liquidity block

`read-state.sh` prints a zero buffer against a non-zero reserve floor, which
looks like a broken invariant and is not. The floor gates new lending:
`deploy()` reverts below it, `settle()` does not, so paying the exit queue can
take the buffer under the floor. The number that carries the information is
the coverage ratio, which is buffer plus contractual inflows plus maturities
inside 30 days against what the queue is owed. Below 100 percent the vault is
saying, to every holder at the same moment and a month before the cash is
needed, that it cannot pay everyone.

That is the whole answer to a depositor being last to see a run, and it is why
there is no weekly gate.
