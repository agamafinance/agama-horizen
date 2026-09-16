#!/usr/bin/env bash
# Build every circuit artefact the Foundry tests consume, and demonstrate that
# the delta circuit refuses a backdated revision.
#
#   ./prove.sh              build proofs + verifiers
#   ./prove.sh --quick      skip regenerating the Solidity verifiers
#   ./prove.sh --zkverify   also build the zk-flavour artefacts zkVerify needs
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.nargo/bin:$HOME/.bb:$PATH"
FIX=../contracts/test/fixtures
mkdir -p "$FIX" scenarios

prove() { # prove <circuit dir> <witness tag> <out tag>
  ( cd "$1" && bb prove --scheme ultra_honk --oracle_hash keccak \
      -b "target/$(basename "$1").json" -w "target/$2.gz" -o "target/proof_$3" >/dev/null )
  cp "$1/target/proof_$3/proof"         "$FIX/proof_$3.bin"
  cp "$1/target/proof_$3/public_inputs" "$FIX/public_inputs_$3.bin"
  echo "  $3: $(wc -c < "$FIX/proof_$3.bin" | tr -d ' ') B proof, \
$(( $(wc -c < "$FIX/public_inputs_$3.bin") / 32 )) public inputs"
}

echo "== book_attest =="
( cd book_attest && nargo compile )
for s in t0 t1; do
  python3 gen.py "$s" >/dev/null
  ( cd book_attest && nargo execute "witness_$s" >/dev/null )
  prove book_attest "witness_$s" "$s"
done

# The t0 Merkle root is a public output of book_attest. The delta circuit takes
# it as a public input, so read it back rather than recomputing it by hand.
python3 gen.py t0 >/dev/null
ROOT=$( cd book_attest && nargo execute witness_root 2>&1 | grep -o 'root: 0x[0-9a-f]*' | cut -d' ' -f2 )
echo "== t0 book root: $ROOT =="

echo "== book_delta, honest revision t0 -> t1 =="
( cd book_delta && nargo compile )
python3 gen.py delta >/dev/null
sed -i '' "s|^old_root = .*|old_root = \"$ROOT\"|" book_delta/Prover.toml
( cd book_delta && nargo execute witness_delta >/dev/null )
prove book_delta witness_delta delta

echo "== book_delta, backdated revision t0 -> evil =="
python3 gen.py evil >/dev/null
sed -i '' "s|^old_root = .*|old_root = \"$ROOT\"|" book_delta/Prover.toml
if ( cd book_delta && nargo execute witness_evil >/dev/null 2>/tmp/evil.err ); then
  echo "  FAIL: the circuit accepted a backdated position" >&2
  exit 1
else
  echo "  refused, as designed: $(grep -o 'Assertion failed: .*' /tmp/evil.err | head -1)"
fi

# leave the honest delta inputs in place for reproducibility
python3 gen.py delta >/dev/null
sed -i '' "s|^old_root = .*|old_root = \"$ROOT\"|" book_delta/Prover.toml

if [ "${1:-}" = "--zkverify" ]; then
  # zkVerify's UltraHonk pallet accepts only the zk flavour, and only a keccak
  # transcript. Same circuit and same witness as above, so the statement is
  # identical to the one the registry verifies directly on Horizen.
  echo "== zkVerify artefacts, zk flavour =="
  python3 gen.py t0 > /dev/null
  ( cd book_attest
    nargo execute witness_zkv > /dev/null
    bb prove    --scheme ultra_honk --zk --oracle_hash keccak \
       -b target/book_attest.json -w target/witness_zkv.gz -o target/zkv > /dev/null
    bb write_vk --scheme ultra_honk      --oracle_hash keccak \
       -b target/book_attest.json -o target/zkv > /dev/null
    bb verify   --scheme ultra_honk --zk --oracle_hash keccak \
       -k target/zkv/vk -p target/zkv/proof -i target/zkv/public_inputs > /dev/null )
  python3 - <<'PYEOF'
d = "book_attest/target/zkv"
hx = lambda p: "0x" + open(f"{d}/{p}", "rb").read().hex()
open(f"{d}/zkv_proof.hex", "w").write(hx("proof") + "\n")
open(f"{d}/zkv_vk.hex", "w").write(hx("vk") + "\n")
pubs = open(f"{d}/public_inputs", "rb").read()
open(f"{d}/zkv_pubs.hex", "w").write(
    "\n".join("0x" + pubs[i*32:(i+1)*32].hex() for i in range(len(pubs)//32)) + "\n")
PYEOF
  cp book_attest/target/zkv/vk "$FIX/zkv_vk.bin"
  cp book_attest/target/zkv/proof "$FIX/zkv_proof.bin"
  echo "  zk proof $(wc -c < book_attest/target/zkv/proof | tr -d ' ') B, \
vk $(wc -c < book_attest/target/zkv/vk | tr -d ' ') B, hex written for zkverify/submit.mjs"
  exit 0
fi

if [ "${1:-}" != "--quick" ]; then
  echo "== Solidity verifiers =="
  ( cd book_attest && bb write_vk --scheme ultra_honk --oracle_hash keccak \
      -b target/book_attest.json -o target/vk_dir >/dev/null
    bb write_solidity_verifier --scheme ultra_honk -k target/vk_dir/vk \
      -o ../../contracts/src/HonkVerifier.sol >/dev/null )
  ( cd book_delta && bb write_vk --scheme ultra_honk --oracle_hash keccak \
      -b target/book_delta.json -o target/vk_dir >/dev/null
    bb write_solidity_verifier --scheme ultra_honk -k target/vk_dir/vk \
      -o ../../contracts/src/DeltaVerifier.sol >/dev/null )
  sed -i '' 's/^contract HonkVerifier is/contract DeltaVerifier is/' ../contracts/src/DeltaVerifier.sol
  echo "  HonkVerifier.sol and DeltaVerifier.sol regenerated"
fi
