#!/usr/bin/env bash
# Dump everything the Agama registry and vault publish on Horizen testnet.
# No arguments, no keys, no trust in us: it only makes eth_call reads.
set -euo pipefail
RPC="${HORIZEN_RPC:-https://horizen-testnet.rpc.caldera.xyz/http}"
REG="${REGISTRY:-0x6D7C4a153C47841fE0A75C3b0a5298E1a3c9229B}"
VAULT="${VAULT:-0x48db9A42098f8eEc6ff14D771D67cA57f3aB5651}"

r() { cast call "$1" "$2" ${3:-} --rpc-url "$RPC" | cut -d' ' -f1; }
u6() { python3 -c "print('%15.2f'%(int('$1')/1e6))"; }
pct() { python3 -c "print('%9.3f %%'%(int('$1')/1e16))"; }
cov() { python3 -c "
v=int('$1')
print('        empty queue' if v > 2**255 else '%9.1f %%'%(v/1e16))"; }

echo "Horizen testnet 2651420 | registry $REG"
echo
cast call "$REG" "surface()" --rpc-url "$RPC" | python3 -c "
import sys
d=sys.stdin.read().strip()[2:]
w=[int(d[i:i+64],16) for i in range(0,len(d),64)]
lab=['<=30d','<=90d','<=180d','<=365d','>365d']
buckets=['current','1-30 dpd','31-60 dpd','61-90 dpd','90+ dpd']
print('book root        0x%064x'%w[0])
print('as of            %d'%w[1])
print('positions        %d'%w[2])
print('principal        %15.2f USDC'%(w[4]/1e6))
print('due next 30d     %15.2f USDC'%(w[5]/1e6))
print('top obligor      %15.2f USDC   %.2f %% of the book'%(w[6]/1e6,100*w[6]/w[4] if w[4] else 0))
print()
print('maturity ladder')
for n,v in zip(lab,w[7:12]):  print('  %-10s %15.2f USDC'%(n,v/1e6))
print()
print('delinquency')
for n,v in zip(buckets,w[12:17]): print('  %-10s %15.2f USDC'%(n,v/1e6))
"
echo
E=$(r "$REG" "currentEpoch()(uint64)")
echo "credit performance"
echo "  epoch                      $E"
echo "  scheduled, published first $(u6 "$(r "$REG" "scheduledFor(uint64)(uint128)" "$E")") USDC"
echo "  realised, observed on-chain$(u6 "$(r "$REG" "realizedFor(uint64)(uint128)" "$E")") USDC"
echo "  performance                $(pct "$(r "$REG" "performanceRatio(uint64)(uint256)" "$E")")"
echo "  impairment, mechanical     $(u6 "$(r "$REG" "impairedPrincipal()(uint256)")") USDC"
echo "  carrying value             $(u6 "$(r "$REG" "carryingValue()(uint256)")") USDC"
echo
echo "disclosure hygiene"
echo "  book revisions committed   $(r "$REG" "bookHistoryLength()(uint256)")"
echo "  independent attestations   $(r "$REG" "attestationCount()(uint256)")"
echo "  seconds since one looked   $(r "$REG" "verificationAge()(uint256)")"
echo "  seconds since a surface    $(r "$REG" "attestationAge()(uint256)")"
echo
echo "vault $VAULT"
echo "  NAV                        $(u6 "$(r "$VAULT" "totalAssets()(uint256)")") USDC"
echo "  first loss remaining       $(u6 "$(r "$VAULT" "firstLossRemaining()(uint256)")") USDC"
echo
echo "liquidity, and what it is telling you"
echo "  liquid buffer              $(u6 "$(r "$VAULT" "buffer()(uint256)")") USDC"
echo "  reserve floor              $(u6 "$(r "$VAULT" "reserveFloor()(uint256)")") USDC"
echo "  exit queue depth           $(r "$VAULT" "queueDepth()(uint256)")"
echo "  queue is owed              $(u6 "$(r "$VAULT" "queuedAssets()(uint256)")") USDC"
echo "  30d coverage of the queue $(cov "$(r "$VAULT" "coverageRatio()(uint256)")")"
cat <<'NOTE'

  The floor gates new lending, not redemption: deploy() reverts below it,
  settle() does not, so paying the queue can and does take the buffer under
  it. Coverage is buffer plus contractual inflows plus maturities inside 30
  days, against what the queue is owed. Below 100 % the vault is saying it
  cannot pay everyone next month, a month before it has to, to every holder
  at once. That is the number, not the weekly gate, that is meant to answer
  "the depositor is last to see a run".
NOTE
