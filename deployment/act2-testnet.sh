#!/usr/bin/env bash
# Act two on the same Horizen testnet deployment.
#
# Act one proved the happy path. This adds the three things a reviewer would
# ask for next: an independent verifier recording that it looked, a real
# multi-party redemption queue settling at one ratio, and the chain publicly
# refusing every attack the design claims to refuse. The refusals are mined
# transactions, not test assertions, so they carry a hash anyone can open.
set -euo pipefail
cd "$(dirname "$0")"

RPC="${HORIZEN_RPC:-https://horizen-testnet.rpc.caldera.xyz/http}"
# Keys never live in this repo. Drop DEPLOYER_PK in .env.local at the root,
# which is ignored, or export it before running.
[ -f ../.env.local ] && set -a && . ../.env.local && set +a
PK="${DEPLOYER_PK:?set DEPLOYER_PK in .env.local or the environment}"
ME=$(cast wallet address "$PK")
EXP=https://horizen-testnet.explorer.caldera.xyz
Z=../zk

REG=$(python3 -c "import json;print(json.load(open('deployment-testnet.json'))['registry'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployment-testnet.json'))['vault'])")
USDC=$(python3 -c "import json;print(json.load(open('deployment-testnet.json'))['testUSDC'])")
ROOT0=$(python3 -c "import json;print(json.load(open('deployment-testnet.json'))['genesisRoot'])")
LOG=act2-testnet.md

say()  { printf '\n\033[1m== %s\033[0m\n' "$*" >&2; }
row()  { echo "$1" >> "$LOG"; }
now()  { cast block latest --rpc-url "$RPC" --json | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["timestamp"],16))'; }

send() { # send <label> <key> <to> <sig> [args...]
  local label=$1 key=$2; shift 2
  local out h g
  out=$(cast send --rpc-url "$RPC" --private-key "$key" --timeout 300 --json "$@")
  h=$(echo "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["transactionHash"])')
  g=$(echo "$out" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["gasUsed"],16))')
  printf '  %-30s %s  %s gas\n' "$label" "$h" "$g" >&2
  row "| \`$label\` | [\`${h:0:18}…\`]($EXP/tx/$h) | succeeded | $g |"
}

# A refusal is reported by what the chain actually did, never by what we hoped
# it would do. The registry checks in increasing cost order, so an attack aimed
# at an expensive guard is often stopped by a cheaper one first, and saying
# otherwise would credit a mechanism that never ran.
errname() { # errname <4-byte selector>
  case "$1" in
    0x4b6e174b) echo "SurfaceNotMonotonic()" ;;
    0xa8337f5a) echo "NotDescendedFromLatest()" ;;
    0x53281ecd) echo "WrongCommitTimestamp()" ;;
    0x57cea9bd) echo "GenesisAlreadySet()" ;;
    0x62df0545) echo "NotVault()" ;;
    0x05b6e6bf) echo "AsOfMismatchesRevision()" ;;
    0x3b46cf57) echo "AsOfInFuture()" ;;
    0x6d752f8b) echo "AsOfBeforeCommit()" ;;
    0xd936631f) echo "LeafBackdated()" ;;
    0xd142b0ce) echo "PrincipalExceedsDisbursed()" ;;
    0xea756801) echo "RootNotCommitted()" ;;
    0xa0bce24f) echo "RootAlreadyCommitted()" ;;
    0x7ca55c77) echo "BadProof()" ;;
    0x28d8a060) echo "BadDeltaProof()" ;;
    0x9fc3a218) echo "SumcheckFailed(), inside the verifier" ;;
    0xa5d82e8a) echo "ShpleminiFailed(), inside the verifier" ;;
    0xe2517d3f) echo "AccessControlUnauthorizedAccount()" ;;
    0xb94abeec) echo "ERC4626ExceededMaxRedeem()" ;;
    0xfe9cceec) echo "ERC4626ExceededMaxWithdraw()" ;;
    0x8acb5f27) echo "QueueFull()" ;;
    0xe248a277) echo "TicketTooSmall()" ;;
    "")         echo "reverted" ;;
    *)          echo "selector $1" ;;
  esac
}

whyrevert() { # whyrevert <hash> -> the revert reason the chain produced
  local h=$1 j from to bn data sel
  j=$(cast tx "$h" --rpc-url "$RPC" --json 2>/dev/null)
  from=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["from"])' 2>/dev/null)
  to=$(printf '%s'   "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["to"])' 2>/dev/null)
  bn=$(printf '%s'   "$j" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["blockNumber"],16))' 2>/dev/null)
  data=$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin)["input"])' 2>/dev/null)
  [ -z "$from" ] && { echo "reverted"; return; }
  sel=$(cast call --rpc-url "$RPC" --from "$from" --block $((bn-1)) "$to" "$data" 2>&1 \
        | grep -oE '0x[a-f0-9]{8}' | head -1)
  errname "$sel"
}

refuse() { # refuse <label> <guard being aimed at> <key> <to> <sig> [args...]
  local label=$1 want=$2 key=$3; shift 3
  local h st got
  # Skip estimation so the refusal is mined and gets a hash anyone can open.
  h=$(cast send --rpc-url "$RPC" --private-key "$key" --gas-limit 4000000 --async "$@" 2>/dev/null || true)
  if [ -z "$h" ]; then printf '  %-34s could not submit\n' "$label" >&2; return; fi
  sleep 6
  st=$(cast receipt "$h" --rpc-url "$RPC" --json 2>/dev/null \
       | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["status"],16))' 2>/dev/null || echo "?")
  if [ "$st" = "0" ]; then
    got=$(whyrevert "$h")
    printf '  %-34s REFUSED  %s\n' "$label" "$got" >&2
    row "| $label | [\`${h:0:18}…\`]($EXP/tx/$h) | **$got** |"
  else
    printf '  %-34s UNEXPECTEDLY SUCCEEDED %s\n' "$label" "$h" >&2
    row "| $label | [\`${h:0:18}…\`]($EXP/tx/$h) | **SUCCEEDED, expected $want** |"
  fi
}
MNE="test test test test test test test test test test test junk"
lpkey() { cast wallet private-key --mnemonic "$MNE" --mnemonic-index "$1"; }

cat > "$LOG" <<EOF
# Act two: independent verification, a real queue, and refusals on-chain

Same deployment as \`deployment-testnet.md\`. Registry \`$REG\`,
vault \`$VAULT\`, chain 2651420.

Every row below is a mined transaction. The refusals are not test assertions:
they are transactions the chain executed and reverted, and each one has a hash
you can open.

| Call | Transaction | Outcome | Gas |
| --- | --- | --- | --- |
EOF

say "1. the verification agent records that it looked"
FIND=$(cast keccak "sampled 12 of 22 positions against originator servicing files, no exception")
send "attest" "$PK" "$REG" "attest(bytes32,uint64,bytes32)" "$ROOT0" \
     "$(cast call "$REG" 'surface()' --rpc-url "$RPC" | python3 -c 'import sys;d=sys.stdin.read().strip()[2:];print(int(d[64:128],16))')" \
     "$FIND"
echo "  attestationCount now $(cast call "$REG" 'attestationCount()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)" >&2

say "2. three more depositors join"
for i in 1 2 3; do
  K=$(lpkey $i); A=$(cast wallet address "$K")
  AMT=$(( i * 100000000000 ))   # 100k, 200k, 300k USDC
  send "fund LP$i gas"      "$PK" "$A" --value 300000000000000
  send "LP$i mint"          "$K"  "$USDC"  "mint(address,uint256)" "$A" "$AMT"
  send "LP$i approve"       "$K"  "$USDC"  "approve(address,uint256)" "$VAULT" "$AMT"
  send "LP$i deposit"       "$K"  "$VAULT" "deposit(uint256,address)" "$AMT" "$A"
done

say "3. everyone queues, then one settlement at one ratio"
for i in 1 2 3; do
  K=$(lpkey $i); A=$(cast wallet address "$K")
  SH=$(cast call "$VAULT" "balanceOf(address)(uint256)" "$A" --rpc-url "$RPC" | cut -d' ' -f1)
  send "LP$i requestRedeem" "$K" "$VAULT" "requestRedeem(uint256)" "$SH"
done
echo "  queue depth $(cast call "$VAULT" 'queueDepth()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1), \
buffer $(cast call "$VAULT" 'buffer()(uint256)' --rpc-url "$RPC" | cut -d' ' -f1)" >&2

declare -a BEFORE ASKED
for i in 1 2 3; do
  A=$(cast wallet address "$(lpkey $i)")
  BEFORE[$i]=$(cast call "$USDC" "balanceOf(address)(uint256)" "$A" --rpc-url "$RPC" | cut -d' ' -f1)
  ASKED[$i]=$(( i * 100000000000 ))
done
B0=$(cast call "$USDC" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | cut -d' ' -f1)
A0=$(cast call "$VAULT" "queuedAssets()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)
send "settle" "$PK" "$VAULT" "settle()"

say "4. fills, read back from the chain"
row ""
row "## Fill ratios in the settlement above"
row ""
row "| Party | Asked, USDC | Received, USDC | Fill |"
row "| --- | ---: | ---: | ---: |"
for i in 1 2 3; do
  A=$(cast wallet address "$(lpkey $i)")
  NOW=$(cast call "$USDC" "balanceOf(address)(uint256)" "$A" --rpc-url "$RPC" | cut -d' ' -f1)
  python3 -c "
paid=$NOW-${BEFORE[$i]}; asked=${ASKED[$i]}
print('  LP$i  asked %9.2f  got %9.2f  fill %6.3f%%'%(asked/1e6,paid/1e6,100*paid/asked))
print('| LP$i, queued last | %.2f | %.2f | %.3f%% |'%(asked/1e6,paid/1e6,100*paid/asked))
" | tee /dev/stderr | tail -1 >> "$LOG"
done
NOWME=$(cast call "$USDC" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC" | cut -d' ' -f1)
python3 -c "
paid=$NOWME-$B0
asked=$A0 - (100000000000+200000000000+300000000000)
print('  founding LP (queued first, in an earlier round)  asked %9.2f  got %9.2f  fill %6.3f%%'%(asked/1e6,paid/1e6,100*paid/asked))
print('| Founding LP, queued first | %.2f | %.2f | %.3f%% |'%(asked/1e6,paid/1e6,100*paid/asked))
" | tee /dev/stderr | tail -1 >> "$LOG"

say "5. the chain refusing what the design says it refuses"
row ""
row "## Attacks submitted to the chain, and refused by it"
row ""
row "| Attack | Transaction | What actually stopped it |"
row "| --- | --- | --- |"

PROOF=$(python3 -c "print('0x'+open('$Z/book_attest/target/live_t0/proof','rb').read().hex())")
PI=$(python3 -c "
d=open('$Z/book_attest/target/live_t0/public_inputs','rb').read()
print('['+','.join('0x'+d[i*32:(i+1)*32].hex() for i in range(len(d)//32))+']')")
# Understate the 90-plus-days bucket by folding it into current.
PI_TAMPERED=$(python3 -c "
d=open('$Z/book_attest/target/live_t0/public_inputs','rb').read()
w=[int.from_bytes(d[i*32:(i+1)*32],'big') for i in range(len(d)//32)]
w[10]+=w[14]; w[14]=0
print('['+','.join('0x%064x'%x for x in w)+']')")
# The same edit, carrying a valuation date the monotonicity guard accepts, so
# the call reaches the verifier instead of dying one guard earlier.
NOW=$(now)
PI_FRESH=$(python3 -c "
d=open('$Z/book_attest/target/live_t0/public_inputs','rb').read()
w=[int.from_bytes(d[i*32:(i+1)*32],'big') for i in range(len(d)//32)]
w[10]+=w[14]; w[14]=0; w[0]=$NOW-30
print('['+','.join('0x%064x'%x for x in w)+']')")
DPROOF=$(python3 -c "print('0x'+open('$Z/book_delta/target/live_delta/proof','rb').read().hex())")
DPI=$(python3 -c "
d=open('$Z/book_delta/target/live_delta/public_inputs','rb').read()
print('['+','.join('0x'+d[i*32:(i+1)*32].hex() for i in range(len(d)//32))+']')")
DPI_LIE=$(python3 -c "
d=open('$Z/book_delta/target/live_delta/public_inputs','rb').read()
w=[int.from_bytes(d[i*32:(i+1)*32],'big') for i in range(len(d)//32)]
w[1]-=200*86400
print('['+','.join('0x%064x'%x for x in w)+']')")
# The same lie, told from the root that is actually current, so the parent
# check passes and the timestamp check is the one that answers.
LATEST=$(cast call "$REG" "latestRoot()(bytes32)" --rpc-url "$RPC" | cut -d' ' -f1)
TCLAT=$(cast call "$REG" "bookCommittedAt(bytes32)(uint64)" "$LATEST" --rpc-url "$RPC" | cut -d' ' -f1)
DPI_CUR=$(python3 -c "
d=open('$Z/book_delta/target/live_delta/public_inputs','rb').read()
w=[int.from_bytes(d[i*32:(i+1)*32],'big') for i in range(len(d)//32)]
w[0]=int('$LATEST',16); w[1]=$TCLAT-200*86400
print('['+','.join('0x%064x'%x for x in w)+']')")

refuse "Understate the 90-plus delinquency bucket"                 "BadProof"               "$PK" "$REG"   "publishSurface(bytes,bytes32[])" "$PROOF" "$PI_FRESH"
refuse "The same tampered inputs, carrying an older valuation date" "SurfaceNotMonotonic"   "$PK" "$REG"   "publishSurface(bytes,bytes32[])" "$PROOF" "$PI_TAMPERED"
refuse "Re-publish a stale surface to restore a flattering impairment" "SurfaceNotMonotonic" "$PK" "$REG"  "publishSurface(bytes,bytes32[])" "$PROOF" "$PI"
refuse "Claim a false previous-commitment date, from the current root" "WrongCommitTimestamp" "$PK" "$REG" "commitRevision(bytes,bytes32[])" "$DPROOF" "$DPI_CUR"
refuse "The same lie, told from a superseded root"                  "NotDescendedFromLatest" "$PK" "$REG"  "commitRevision(bytes,bytes32[])" "$DPROOF" "$DPI_LIE"
refuse "Replay the revision to fork history off an old root"        "NotDescendedFromLatest" "$PK" "$REG"  "commitRevision(bytes,bytes32[])" "$DPROOF" "$DPI"
refuse "Declare a second genesis book"                              "GenesisAlreadySet"      "$PK" "$REG"   "commitBook(bytes32)" "$ROOT0"
refuse "Raise the disbursement ceiling without moving cash"          "NotVault"               "$PK" "$REG"   "recordDeployment(bytes32,uint256)" "$ROOT0" 100000000000000
refuse "Disburse from the vault without the role"                    "AccessControl"          "$(lpkey 1)" "$VAULT" "deploy(address,uint256,bytes32)" "$ME" 1000000 "$ROOT0"
refuse "Jump the queue through \`redeem\`"                            "maxRedeem is zero"      "$PK" "$VAULT" "redeem(uint256,address,address)" 1000000 "$ME" "$ME"

say "6. final state"
E=$(cast call "$REG" "currentEpoch()(uint64)" --rpc-url "$RPC" | cut -d' ' -f1)
for q in "attestationCount()(uint256)" "verificationAge()(uint256)" "bookHistoryLength()(uint256)" "impairedPrincipal()(uint256)" "carryingValue()(uint256)"; do
  printf '  %-26s %s\n' "$q" "$(cast call "$REG" "$q" --rpc-url "$RPC" | cut -d' ' -f1)" >&2
done
printf '  %-26s %s\n' "performanceRatio($E)" "$(cast call "$REG" "performanceRatio(uint64)(uint256)" "$E" --rpc-url "$RPC" | cut -d' ' -f1)" >&2
for q in "totalAssets()(uint256)" "firstLossRemaining()(uint256)" "queueDepth()(uint256)" "buffer()(uint256)"; do
  printf '  %-26s %s\n' "$q" "$(cast call "$VAULT" "$q" --rpc-url "$RPC" | cut -d' ' -f1)" >&2
done
say "done, log in $LOG"
