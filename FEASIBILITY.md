# Agama on Horizen: feasibility study

Everything below was measured, not read off a marketing page. Where a claim
comes from Horizen's own docs it is quoted and sourced. Where it comes from a
test, the test is in this repo and reproducible.

Date of measurement: 15 September 2026.

---

## 1. What is actually live

### Horizen Chain, mainnet

| Property | Measured value |
| --- | --- |
| Chain ID | 26514 (`eth_chainId` returns `0x6792`) |
| RPC | `https://horizen.calderachain.xyz/http` |
| Stack | OP Stack rollup on Caldera, settles to Base, Base settles to Ethereum |
| Gas token | ETH |
| Block time | 1.00 s measured over 50,000 blocks |
| Gas price | 1,000,764 wei, about 0.001 gwei |
| Block gas limit | 30,000,000 |
| Activity | 307 transactions across the last 300 blocks, roughly one per block |
| USDC.e total supply | **3,166.65 USDC** |

The last row is the important one. Horizen mainnet is live, cheap and fast, and
has essentially no stablecoin on it. There is nothing to lend and nothing to
lend against. Any credit product here is not competing for existing liquidity,
it is the reason liquidity would arrive.

The gas price has a second consequence that shapes the whole design: on-chain
zero-knowledge verification is free in practice. See section 4.

### Live contracts, verified on-chain

| Contract | Address | Bytecode |
| --- | --- | --- |
| PureFi Verifier (proxy) | `0x681Edd4906e2a0a277E2A6c394A4595f83e1329c` | 2,008 B |
| PureFi Verifier (impl) | `0x61C468B554B6F0b0842242F7Df079bb392EE0555` | 8,505 B |
| Stork Oracle | `0xacC0a0cF13571d30B4b8637996F5D6D774d4fd62` | 170 B |
| USDC.e | `0xDF7108f8B10F9b9eC1aba01CCa057268cbf86B6c` | 1,798 B |
| ZEN OFT | `0x57da2D504bf8b83Ef304759d9f2648522D7a9280` | 12,539 B |
| cbBTC OFT | `0x68fb5BB8330C0b9d907F50f278143873276ee056` | 12,539 B |

PureFi is real and callable today. Our fork test gates a vault deposit on it
and confirms the transaction reverts as a unit when the payload is invalid
(`test_PureFiIsLiveOnHorizen`).

### Horizen Chain, testnet

Chain ID 2651420, `https://horizen-testnet.rpc.caldera.xyz/http`, live and
responding. Faucet at `hub-testnet.horizen.io` requires a browser session, so
testnet deployment needs one manual funding step.

---

## 2. Vela: what it is and what it is not

Vela is a confidential coprocessor. WASM applications run inside AWS Nitro
Enclaves, state is encrypted with AES-256 under a key that never leaves the
enclave, and the enclave signs every state transition with a secp256k1 key
registered on-chain in `TeeAuthenticator`.

We ran the full stack locally from `HorizenOfficial/vela-starterkit` v0.2.0 and
executed a complete confidential lifecycle:

```
deploy WASM into the enclave      applicationId 7335106231336828932
register P-521 user key           ASSOCIATEKEY, settled on-chain
deposit 1 ETH                     private balance readable only by the key holder
grant deanonymisation authority   DefaultAuthority.addAllowedAuthority, public event
request deanonymisation report    settled on-chain, ReportGenerated
download and decrypt report       full private balance set recovered
```

That last step matters: a designated authority, and only a designated
authority, can pull the private state, and **the act of pulling it is an
on-chain transaction that everyone can see**. That is the mechanism the whole
architecture hangs off.

### The blocking constraint

Horizen's own limitations page states it plainly:

> "VELA is not yet deployed to any testnet or mainnet environment. All
> development and testing happens locally using Docker."

> "The development environment uses an emulated Trusted Execution Environment
> rather than hardware enclaves. Applications lack hardware-level attestation
> guarantees."

The local stack confirms it. `TEE_NO_ATTESTATION=true`, and the three enclave
keys sit in plaintext in `.env.dev`:

```
EXECUTOR_FIXED_SIGNING_KEY='79ec8072d24d68aaabf6dbe06416d635b66bf6042847d447a5a14f867b2da7cf'
EXECUTOR_FIXED_COMMUNICATION_KEY='00b2df45d29db7b6a314100cbff4abde8106254204205eb0653662a5fc41a6e48b...'
EXECUTOR_FIXED_STATE_KEY='74ffca703f8c04292a849bfc7c6389f4e193ac13300896a74c319753c2f1f66a'
```

**Conclusion: in September 2026 a Vela dependency cannot sit on the critical
path of a mainnet product.** Anyone claiming a hardware trust guarantee from
Vela today is claiming something the software does not yet provide. The
architecture in this repo therefore treats Vela as a Phase 2 upgrade, not a
Phase 1 prerequisite, and ships its confidentiality on commitments and proofs
that work on Horizen mainnet now.

### What Vela leaks, by design

This is not a criticism, it is a design input, and it happens to be exactly
what a credit vault wants. From `IProcessorEndpoint.sol` and confirmed on the
local chain:

| Public | Private |
| --- | --- |
| Sender address of every request | Request payload |
| `assetAmount` on every deposit (a plain calldata field) | Internal ledger state |
| Withdrawal recipient, token and amount | Per-user balances |
| Request timing, success or failure | `UserEvent` contents (P-521 encrypted) |
| State root after every transition | |
| `AppEvent` contents, chosen by the app | |
| Every authority grant, revocation and report request | |

**Vela's perimeter is public and its interior is private.** Money entering and
leaving is fully visible with amounts and addresses. Only the internal
bookkeeping is hidden. For a confidential credit vault this is the right shape:
we want the cash rail public and the borrower list private.

### Other Vela constraints found

- One WASM application per environment (v0.2.0).
- TinyGo only, no `reflect`, no `net`, no `math/big`, strict determinism: no
  `time.Now()`, no randomness.
- Execution is stateless per call; the whole app state is serialised in and out
  of every invocation, which caps practical book size.
- A counterparty must register a P-521 key before it can receive anything. Our
  private transfer failed with `no Secp521r1_PubKey found` until the receiver
  registered. Every borrower and LP has to be onboarded with a key.
- `DEANONYMIZATION` requests revert with `AuthorityNotAllowed` unless the caller
  is in the registry. The gate works, and `AuthorityRegistry.setAppAuthorityContract`
  lets an application supply its own checker contract, so the rule for who may
  look can itself be a smart contract.

---

## 3. zkVerify

zkVerify is live as its own L1 and its EVM contracts are deployed on Base,
Sepolia, Base Sepolia, Arbitrum Sepolia, Optimism Sepolia and EDU Chain
Testnet. **Not on Horizen L3.** Consuming a zkVerify aggregation from a Horizen
contract would need a relayer that Horizen does not currently run.

More to the point, zkVerify's value proposition is cost: it exists because
verifying a proof on Ethereum L1 costs 200,000 to 300,000 gas at L1 gas prices.
On Horizen at 0.001 gwei that argument disappears. We measured direct on-chain
verification below.

**Recommendation: verify proofs directly on Horizen. Treat zkVerify as an
optional later optimisation for cross-originator aggregation, not as a
dependency.**

---

## 4. Zero-knowledge, measured

We built a real circuit rather than describing one. `zk/book_attest`
proves that a published set of credit risk aggregates is the honest evaluation
of a privately held loan book committed to on-chain.

Private input: 64 loan slots (obligor, principal, maturity, next payment date,
amount due, delinquency status, commitment timestamp, blinding salt).

Public output: Merkle root, position count, outstanding principal, a five-bucket
maturity ladder, contractual cash due over the next 30 days, principal by
delinquency bucket, largest single-obligor exposure, newest commitment
timestamp.

| Metric | Value |
| --- | --- |
| Circuit | Noir 1.0.0-beta.13, UltraHonk, keccak oracle |
| ACIR opcodes | 65,939 |
| Circuit size | 2^18 |
| Proving time | 3.0 s, laptop, 14 threads |
| Both scenario proofs end to end | 4.3 s |
| Proof size | 14,592 bytes |
| Public inputs | 17 field elements, 544 bytes |
| Solidity verifier runtime size | 22,063 B (limit 24,576, margin 2,513) |

### On-chain verification cost, on a fork of Horizen mainnet

| Operation | Gas | ETH | USD at 3,000 |
| --- | ---: | ---: | ---: |
| `commitBook` | 98,485 | 0.0000000986 | 0.00030 |
| `deposit` (ERC-4626) | 127,087 | 0.0000001272 | 0.00038 |
| **`publishSurface` (full UltraHonk verification)** | **2,178,509** | 0.0000021802 | **0.0065** |
| `settle` (2 queue tickets) | 85,100 | 0.0000000852 | 0.00026 |

Proving a complete confidential credit book and verifying it on-chain costs
about **two thirds of a US cent**. Daily attestation costs under 2.40 USD a
year. There is no economic reason to attest monthly rather than daily, which
changes what the product can promise.

One caveat worth stating: the verifier is 22,063 bytes against a 24,576 byte
limit. Growing the public input set materially will require splitting the
verifier or moving to a proof system with a smaller verifier.

---

## 4b. Deployed, not described

Everything above was then put on Horizen testnet, chain 2651420, and run end to
end. Not a fork and not a simulation.

| Contract | Address |
| --- | --- |
| CreditDisclosureRegistry | `0x034635c324d83D590691C68d711AA5FA2FbA084f` |
| AgamaCreditVault | `0x58b90F2aA6C48B19B8792Bf4a5dcd2437Ae8FfA9` |
| HonkVerifier | `0x57D463c6449eb25425D0137ca9E296A67c0486d1` |
| DeltaVerifier | `0xBD913f10e18C32b7c035f920B95CB24eE4B2acA9` |

The cycle that ran on-chain: book committed before any cash moved, vault funded,
first loss posted, 4.76 M disbursed, risk surface proven and verified, a short
collection recorded, a revision proven to descend from the committed book,
the deteriorated surface published, queue settled pro-rata.

| Operation | Gas on testnet |
| --- | ---: |
| `publishSurface` with UltraHonk verification | 2,364,725 |
| `commitRevision` with delta verification | 2,222,133 |
| `publishSurface`, revised surface | 2,192,539 |
| `settle` | 135,433 |

**The whole deployment plus the full cycle cost 0.000000027 ETH.**

Readable from the registry by anyone: 22 positions, 4,760,000 USDC principal,
22.06 percent top-name concentration, 246,500 USDC of mechanical impairment,
253,500 of 500,000 first loss remaining, two committed book revisions, and
epoch 0 performance at **35.83 percent** against a calendar of 33,487.50 USDC
that was published before the period began.

Transaction hashes: `deployment/deployment-testnet.md`.

## 5. Verdict

| Component | Status | Usable in Phase 1 |
| --- | --- | --- |
| Horizen mainnet, EVM, ERC-4626 | Live, 1 s blocks, ~free gas | Yes |
| USDC.e | Live, 3,166 USDC outstanding | Yes, but we bring the liquidity |
| PureFi AML/KYC | Live, verified callable | Yes |
| Stork oracle | Live | Yes, not needed at Phase 1 |
| Direct on-chain ZK verification | Measured, 2.18 M gas, 0.0065 USD | **Yes** |
| zkVerify | Live, but not deployed on Horizen L3 | No |
| Vela TEE | Closed beta, local Docker only, no attestation | **No** |

**A confidential credit vault is buildable on Horizen mainnet today, provided
its confidentiality comes from commitments plus proofs rather than from Vela.**
It is already built and running on testnet. Thirty tests cover it: seven against
a live fork of mainnet chain 26514, seventeen adversarial, six stateful
invariants over 4,096 randomised calls. The case the reviewer raised, a clean
signature on top of a bad book, is one of them, and the book fails its own
calendar exactly as designed.

Vela remains the right Phase 2 destination: it replaces off-chain proving with
in-enclave computation and gives the verification agent a first-class
deanonymisation channel with the access request recorded on-chain. It is an
upgrade to a working system, not a promise standing in for one.
