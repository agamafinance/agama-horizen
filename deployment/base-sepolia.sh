#!/usr/bin/env bash
# Put the zkVerify consumer on Base Sepolia and admit a surface through it.
#
# Two contracts go up. ZkVerifyRiskSurface pointed at zkVerify's own aggregation
# contract, which is the one that would be used once roots are relayed here. And
# a second copy pointed at a stand-in holding the root zkVerify actually
# published for our proof, because no domain relays to any EVM chain today: on
# Volta and on mainnet alike, hp_dispatch::Destination has one variant and it is
# None. One hop is copied across by hand; everything downstream of it is real.
set -euo pipefail
cd "$(dirname "$0")"

RPC="${BASE_SEPOLIA_RPC:-https://sepolia.base.org}"
PK="${DEPLOYER_PK:?set DEPLOYER_PK}"
ME=$(cast wallet address "$PK")
C=../contracts
EXP=https://sepolia.basescan.org

# From zk/zkverify/aggregation.json, published by zkVerify on Volta.
ZKV_LIVE=0x312468EbF274F1f584d93d0CCA8458cC91460FC0
DOMAIN=10
AGG=2
ROOT=0xb2ee6f0eb55cd0a4452c30da159adcfda7e6c0f227a22cb30c39229416946564
STATEMENT=0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730
VK_HASH=0x5da1b785ba7eb5ff008935ce60182447b79a4d171b1b1f1f0722e5e8fc7c9b78

say() { printf '\n\033[1m== %s\033[0m\n' "$*" >&2; }
create() {
  local name=$1 what=$2; shift 2
  local out addr
  # Deployments fired back to back race on the nonce and come back "already
  # known", so each one waits for the previous to land before starting.
  out=$( (cd $C && forge create "$what" --rpc-url "$RPC" --private-key "$PK" --broadcast --json "$@") 2>/dev/null )
  addr=$(echo "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])')
  printf '  %-26s %s\n' "$name" "$addr" >&2
  until [ "$(cast code "$addr" --rpc-url "$RPC" | wc -c | tr -d ' ')" -gt 4 ]; do sleep 2; done
  echo "$addr"
}
send() {
  local label=$1; shift
  local out h g
  out=$(cast send --rpc-url "$RPC" --private-key "$PK" --json "$@")
  h=$(echo "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["transactionHash"])')
  g=$(echo "$out" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["gasUsed"],16))')
  printf '  %-26s %s  %s gas\n' "$label" "$h" "$g" >&2
  echo "$h"
}

echo "chain    $(cast chain-id --rpc-url "$RPC")"
echo "deployer $ME"
echo "balance  $(cast balance "$ME" --rpc-url "$RPC" --ether) ETH"

say "1. consumer pointed at zkVerify's own aggregation contract"
LIVE=$(create "ZkVerifyRiskSurface" src/ZkVerifyRiskSurface.sol:ZkVerifyRiskSurface \
        --constructor-args "$ZKV_LIVE" "$VK_HASH" "$DOMAIN")

say "2. stand-in holding the root zkVerify published, and a consumer on it"
STAND=$(create "AggregationStandIn" src/AggregationStandIn.sol:AggregationStandIn \
        --constructor-args "$DOMAIN" "$AGG" "$ROOT")
DEMO=$(create "ZkVerifyRiskSurface (demo)" src/ZkVerifyRiskSurface.sol:ZkVerifyRiskSurface \
        --constructor-args "$STAND" "$VK_HASH" "$DOMAIN")

say "3. admit the surface through the real root"
PI=$(python3 -c "
d=open('$C/test/fixtures/public_inputs_t0.bin','rb').read()
print('['+','.join('0x'+d[i*32:(i+1)*32].hex() for i in range(len(d)//32))+']')")
echo "  leaf our consumer computes: $(cast call "$DEMO" 'leafFor(bytes32[])(bytes32)' "$PI" --rpc-url "$RPC")" >&2
echo "  statement zkVerify returned: $STATEMENT" >&2
TX=$(send "admit" "$DEMO" "admit(uint256,bytes32[],uint256,uint256,bytes32[])" "$AGG" "[]" 1 0 "$PI")

say "4. what anyone can now read on Base Sepolia"
cast call "$DEMO" "surface()" --rpc-url "$RPC" | python3 -c "
import sys
d=sys.stdin.read().strip()[2:]
w=[int(d[i:i+64],16) for i in range(0,len(d),64)]
print('  positions       ', w[2])
print('  principal        %.2f USDC' % (w[4]/1e6))
print('  due next 30d     %.2f USDC' % (w[5]/1e6))
print('  top obligor      %.2f USDC' % (w[6]/1e6))
print('  delinquent 90+   %.2f USDC' % (w[16]/1e6))
"

python3 - "$LIVE" "$STAND" "$DEMO" "$TX" > base-sepolia.json <<'PY'
import json, sys
k = ["consumerOnLiveZkVerify", "aggregationStandIn", "consumerOnStandIn", "admitTx"]
d = dict(zip(k, sys.argv[1:5]))
d.update(chainId=84532, explorer="https://sepolia.basescan.org",
         zkVerifyAggregationContract="0x312468EbF274F1f584d93d0CCA8458cC91460FC0",
         domainId=10, aggregationId=2,
         root="0xb2ee6f0eb55cd0a4452c30da159adcfda7e6c0f227a22cb30c39229416946564",
         statement="0x0f3c234e17e8b7c35e1621b7f6b183a99998a5a25fc42db4760fb357905af730")
print(json.dumps(d, indent=2))
PY
say "done"
cat base-sepolia.json
