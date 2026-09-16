# zkVerify on Base Sepolia

Chain 84532. All three contracts are source-verified on Blockscout, so the code
running at these addresses can be read rather than trusted.

| Contract | Address | What it is |
| --- | --- | --- |
| `ZkVerifyRiskSurface` | [`0x7FcA842Ce1e27270E24d828a340B48083f237212`](https://base-sepolia.blockscout.com/address/0x7FcA842Ce1e27270E24d828a340B48083f237212) | Pointed at zkVerify's own aggregation contract. The deployment that would be used once roots are relayed here |
| `AggregationStandIn` | [`0x2A719C5c053d66Dcb029110DB420d8191b287b54`](https://base-sepolia.blockscout.com/address/0x2A719C5c053d66Dcb029110DB420d8191b287b54) | Holds the root zkVerify published for our proof |
| `ZkVerifyRiskSurface` | [`0xB29E7b13C2c84AFADe8dFd143dD1d0140F6AbF4a`](https://base-sepolia.blockscout.com/address/0xB29E7b13C2c84AFADe8dFd143dD1d0140F6AbF4a) | The same consumer, pointed at that root |
| zkVerify aggregation | [`0x312468Eb…`](https://base-sepolia.blockscout.com/address/0x312468EbF274F1f584d93d0CCA8458cC91460FC0) | Theirs, 17,826 bytes, live |

## The leaf, computed on Base Sepolia

```
leafFor(publicInputs) on-chain   0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730
statement zkVerify returned      0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730
```

The contract reproduces, on Base Sepolia, the statement zkVerify hashed on Volta.
Nothing was passed in: the leaf is derived from the seventeen public inputs and
the verification key bound at deployment.

## Admitting the surface

`admit` transaction
[`0x5a88bdb5…`](https://base-sepolia.blockscout.com/tx/0x5a88bdb53750a016cd498cdd1d7a4d1c74a4384aa10f3d8d24c45a31cfe3c8b1),
**266,041 gas**, succeeded. What the consumer now publishes, readable by anyone:

| Reading | Value |
| --- | --- |
| book root | `0x218147fc…` |
| as of | 1789500000 |
| positions | 22 |
| outstanding principal | 4,760,000.00 USDC |
| cash due over 30 days | 33,487.50 USDC |
| largest obligor | 1,050,000.00 USDC, 22.06 percent |
| maturity ladder | 190k / 660k / 995k / 1,530k / 1,385k |
| delinquency | 4,215k / 435k / 0 / 0 / 110k |
| aggregation admitted | 2 |

The same numbers the registry publishes on Horizen, arrived at by a different
route: a pairing check there, a Merkle inclusion check here.

## What is real and what is not

**Real.** The proof, verified by zkVerify on Volta. The statement it returned.
The aggregation root it published for domain 10 aggregation 2 at block
`0x761aa9e3…`. The leaf our contract computes on Base Sepolia, which matches
that statement exactly. The inclusion check and the decoding.

**Not real.** One hop. The root was copied from Volta to Base Sepolia by us
rather than relayed by zkVerify, and it sits in `AggregationStandIn` rather than
in their contract.

We could not close that hop, and the reason is worth recording. A zkVerify domain
carries a `delivery` field with a destination. On both Volta and zkVerify mainnet
today, reading the runtime metadata, `hp_dispatch::Destination` has exactly one
variant:

```
Volta (testnet)    : None
zkVerify (mainnet) : None
```

No domain setting relays a root anywhere. Roots reach EVM chains through a
relayer zkVerify operates, which an application cannot configure for itself. That
is a very different constraint from a missing deposit, and it is why more testnet
tokens would not have helped.

Proof that the other deployment behaves correctly without the stand-in: calling
`admit` on [`0x7FcA842Ce1e27270E24d828a340B48083f237212`](https://base-sepolia.blockscout.com/address/0x7FcA842Ce1e27270E24d828a340B48083f237212), which
points at zkVerify's real contract, reverts with `NotAggregated`. Our aggregation
is genuinely not there.

## Reproduce

```sh
DEPLOYER_PK=0x... ./deployment/base-sepolia.sh
```
