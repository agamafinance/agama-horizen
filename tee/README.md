# Vela, what we ran and what we found

Reproduces the local Vela test described in `../FEASIBILITY.md` section 2.

## Bring up the stack

```sh
git clone --depth 1 https://github.com/HorizenOfficial/vela-starterkit.git
cd vela-starterkit/dockerfiles
cp .env.dev .env
docker compose up -d
```

Nine containers: Anvil chain, contract deployer, executor (emulated enclave),
manager, authority service, and a Graph Node stack. Exposed on the host:
8545 (RPC), 8081 (authority service), 8000 (subgraph).

Deployed addresses, deterministic on Anvil:

```
ProcessorEndpoint    0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
TeeAuthenticator     0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
TokenAllowlist       0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
AuthorityRegistry    0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
DefaultAuthority     0x5FbDB2315678afecb367f032d93F642f64180aa3
```

Confirm the enclave handshake completed and its signing key is registered
on-chain:

```sh
docker logs vela-skit-manager 2>&1 | grep "Executor's signing key"
cast call 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 "getTeeSigner()(address)" \
  --rpc-url http://localhost:8545
# 0x2a0fba02cee7fb70899648037c7E8203881e2D55, both agree
```

## Run the confidential lifecycle

The reference app and wallet come from `HorizenOfficial/vela-nova` v0.2.0. The
wallet is a linux/amd64 binary, so on Apple Silicon run it in a container:

```sh
gh release download v0.2.0 --repo HorizenOfficial/vela-nova
chmod +x novaw-linux
run() { docker run --rm --platform linux/amd64 \
          --add-host=host.docker.internal:host-gateway \
          -v "$PWD:/w" -w /w debian:bookworm-slim ./novaw-linux "$@"; }

run generatekeys                     # P-521 + secp256k1, paste into wallet.conf
run deployapp --wasm /w/payment_app.wasm --max-value-fee "100 wei"
run registeruser --max-value-fee "1000 wei"
run deposit -a "1 ETH" --max-value-fee "1000 wei"
run getprivatebalance                # 1 ETH, readable only with the P-521 key
```

`wallet.conf` points at `http://host.docker.internal:8545`, `:8081` and
`:8000/subgraphs/name/hcce`.

## The deanonymisation flow

This is the mechanism the architecture depends on. Authority is granted
on-chain, publicly:

```sh
cast send 0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  "addAllowedAuthority(uint256,address)" $APP_ID $AUTHORITY \
  --private-key $ADMIN_KEY --rpc-url http://localhost:8545
```

Then, and only then:

```sh
run requestreport --report-type balances --max-value-fee "100000 wei"
run downloadreport --report-id <id> --dest /w/report.json
```

The enclave produced the report, encrypted it to the authority's P-521 key, and
the authority decrypted it:

```json
{
  "applicationId": "7335106231336828932",
  "reportData": { "accounts": { "0xf39f…2266": { "balances": { "0x00…00": "0xde0b6b3a7640000" } } } },
  "authority": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
}
```

Without the grant, the same call reverts with
`ProcessorEndpointAuthorityNotAllowed`. The gate works, and both the grant and
the request are public transactions.

## Findings

1. **Vela works, and is not deployable.** Horizen's own limitations page:
   "VELA is not yet deployed to any testnet or mainnet environment." The dev
   stack runs `TEE_NO_ATTESTATION=true` with all three enclave keys in plaintext
   in `.env.dev`. There is no hardware guarantee to rely on yet.
2. **The perimeter is public.** `submitRequest(..., address tokenAddress,
   uint256 assetAmount, uint256 maxFeeValue)` puts deposit amounts in plain
   calldata, and `RequestSubmitted` indexes the sender. Deposits and withdrawals
   are fully visible; only the internal ledger is private. For a credit vault
   that is the shape we want.
3. **Counterparties must be pre-registered.** A private transfer to an address
   with no P-521 key fails with `no Secp521r1_PubKey found`. Every borrower and
   LP needs onboarding before they can receive anything.
4. **Report types are application-defined.** The reference app exposes
   `balances` and `tx_history` with a time range. A credit application defines
   its own, which is how a verification agent gets a scoped view of the book
   rather than all of it.
5. **`AuthorityRegistry.setAppAuthorityContract`** lets an application install
   its own authority checker, so the rule for who may look can be a contract.
   That is what Phase 2 uses.

## Tear down

```sh
docker compose down
docker volume ls -q | grep vela-skit | xargs -r docker volume rm
```
