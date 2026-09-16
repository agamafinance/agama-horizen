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
| Registry | [`0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B`](https://horizen-testnet.explorer.caldera.xyz/address/0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B) |
| Vault | [`0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651`](https://horizen-testnet.explorer.caldera.xyz/address/0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651) |
| ZK verifier | [`0xb95B360324edbfd324e19196F6fF3B97E9EaA7dA`](https://horizen-testnet.explorer.caldera.xyz/address/0xb95B360324edbfd324e19196F6fF3B97E9EaA7dA) |
| Revision verifier | [`0xA3C1e81Fdadb5bd098546A4B8FBDfe4169436cF4`](https://horizen-testnet.explorer.caldera.xyz/address/0xA3C1e81Fdadb5bd098546A4B8FBDfe4169436cF4) |
| Test USDC | [`0xd0c379C0cD56b62fd9c2fE8913aa261f8096164e`](https://horizen-testnet.explorer.caldera.xyz/address/0xd0c379C0cD56b62fd9c2fE8913aa261f8096164e) |

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
