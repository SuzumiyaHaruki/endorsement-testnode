#!/usr/bin/env bash
set -euo pipefail

L2_RPC_URL="${L2_RPC_URL:-http://127.0.0.1:8547}"

# 已有资金的开发账户私钥
FUNDER_KEY="${FUNDER_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"

# 每个新实验账户的充值金额
FUND_AMOUNT="${FUND_AMOUNT:-1.5ether}"

OUT_ENV="${1:-./accounts.env}"

# 本地 nonce 缓存文件：用于避免 RPC 返回过旧 nonce 时倒退
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd cast
need_cmd awk
need_cmd sed
need_cmd tr
need_cmd jq
need_cmd python3
need_cmd grep
need_cmd cat

make_wallet() {
  cast wallet new 2>/dev/null
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

extract_address() {
  awk -F': ' '/Address/ {print $2}' | trim
}

extract_private_key() {
  awk -F': ' '/Private key/ {print $2}' | trim
}

validate_hex_address() {
  local addr="$1"
  [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

validate_hex_privkey() {
  local key="$1"
  [[ "$key" =~ ^0x[0-9a-fA-F]{64}$ ]]
}

validate_tx_hash() {
  local h="$1"
  [[ "$h" =~ ^0x[0-9a-fA-F]{64}$ ]]
}

wait_for_receipt_success() {
  local tx_hash="$1"
  local rpc_url="$2"

  for _ in $(seq 1 90); do
    local receipt
    receipt=$(cast receipt "$tx_hash" --rpc-url "$rpc_url" --json 2>/dev/null || true)
    if [[ -n "$receipt" && "$receipt" != "null" ]]; then
      local status
      status=$(jq -r '.status // ""' <<<"$receipt")
      if [[ "$status" == "1" || "$status" == "0x1" ]]; then
        return 0
      fi
      echo "[!] funding tx mined but failed: $tx_hash (status=$status)" >&2
      return 1
    fi
    sleep 1
  done

  echo "[!] timeout waiting for receipt: $tx_hash" >&2
  return 1
}

balance_to_wei() {
  local bal_str="$1"

  if [[ "$bal_str" =~ ^[0-9]+$ ]]; then
    echo "$bal_str"
    return 0
  fi

  if [[ "$bal_str" =~ ^([0-9]+)(\.[0-9]+)?[[:space:]]*ETH$ ]]; then
    python3 - <<PY
from decimal import Decimal
s = """$bal_str""".strip().replace(" ETH", "")
print(int(Decimal(s) * (10 ** 18)))
PY
    return 0
  fi

  local compact
  compact="$(echo "$bal_str" | tr -d '[:space:]')"
  if [[ "$compact" =~ ^[0-9]+$ ]]; then
    echo "$compact"
    return 0
  fi

  echo "0"
}

wait_for_min_balance() {
  local addr="$1"
  local rpc_url="$2"
  local min_eth="$3"

  local min_wei
  min_wei=$(python3 - <<PY
from decimal import Decimal
print(int(Decimal("$min_eth") * (10 ** 18)))
PY
)

  for _ in $(seq 1 90); do
    local bal_raw bal_wei
    bal_raw=$(cast balance "$addr" --rpc-url "$rpc_url" 2>/dev/null || echo "0")
    bal_wei=$(balance_to_wei "$bal_raw")

    if [[ "$bal_wei" =~ ^[0-9]+$ ]] && [[ "$bal_wei" -ge "$min_wei" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "[!] timeout waiting for funded balance on account: $addr" >&2
  return 1
}

hex_to_dec() {
  local v="$1"
  python3 - <<PY
print(int("$v", 16))
PY
}

rpc_get_nonce_by_tag() {
  local addr="$1"
  local tag="$2"
  local rpc_url="$3"

  local raw
  raw="$(cast rpc eth_getTransactionCount "$addr" "$tag" --rpc-url "$rpc_url" 2>/dev/null | tr -d '"[:space:]')"
  if [[ ! "$raw" =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo ""
    return 1
  fi

  hex_to_dec "$raw"
}

get_chain_nonce_max() {
  local addr="$1"
  local rpc_url="$2"

  local latest pending
  latest="$(rpc_get_nonce_by_tag "$addr" latest "$rpc_url" || true)"
  pending="$(rpc_get_nonce_by_tag "$addr" pending "$rpc_url" || true)"

  if [[ ! "$latest" =~ ^[0-9]+$ ]]; then
    latest=0
  fi
  if [[ ! "$pending" =~ ^[0-9]+$ ]]; then
    pending=0
  fi

  if (( pending > latest )); then
    echo "$pending"
  else
    echo "$latest"
  fi
}

get_cached_nonce_plus_one() {
  if [[ -f "$NONCE_CACHE_FILE" ]]; then
    local cached
    cached="$(tr -d '[:space:]' < "$NONCE_CACHE_FILE" 2>/dev/null || true)"
    if [[ "$cached" =~ ^[0-9]+$ ]]; then
      echo $((cached + 1))
      return 0
    fi
  fi
  echo 0
}

get_safe_next_nonce() {
  local addr="$1"
  local rpc_url="$2"

  local chain_nonce cached_next
  chain_nonce="$(get_chain_nonce_max "$addr" "$rpc_url")"
  cached_next="$(get_cached_nonce_plus_one)"

  if [[ ! "$chain_nonce" =~ ^[0-9]+$ ]]; then
    chain_nonce=0
  fi
  if [[ ! "$cached_next" =~ ^[0-9]+$ ]]; then
    cached_next=0
  fi

  if (( cached_next > chain_nonce )); then
    echo "$cached_next"
  else
    echo "$chain_nonce"
  fi
}

record_used_nonce() {
  local used_nonce="$1"
  echo "$used_nonce" > "$NONCE_CACHE_FILE"
}

send_funding_tx() {
  local to_addr="$1"
  local amount="$2"
  local nonce="$3"

  cast send "$to_addr" \
    --value "$amount" \
    --private-key "$FUNDER_KEY" \
    --rpc-url "$L2_RPC_URL" \
    --nonce "$nonce" \
    --json
}

FUNDER_ADDR="$(cast wallet address --private-key "$FUNDER_KEY" 2>/dev/null | tr -d '\r\n')"
if ! validate_hex_address "$FUNDER_ADDR"; then
  echo "[!] invalid FUNDER address derived from FUNDER_KEY: '$FUNDER_ADDR'" >&2
  exit 1
fi

touch "$NONCE_CACHE_FILE"

echo "[*] creating KEEP account"
KEEP_INFO="$(make_wallet)"
KEEP_ADDR="$(echo "$KEEP_INFO" | extract_address)"
KEEP_KEY="$(echo "$KEEP_INFO" | extract_private_key)"

echo "[*] creating FAIL account"
FAIL_INFO="$(make_wallet)"
FAIL_ADDR="$(echo "$FAIL_INFO" | extract_address)"
FAIL_KEY="$(echo "$FAIL_INFO" | extract_private_key)"

if ! validate_hex_address "$KEEP_ADDR"; then
  echo "[!] invalid KEEP address parsed: '$KEEP_ADDR'" >&2
  echo "$KEEP_INFO" >&2
  exit 1
fi

if ! validate_hex_address "$FAIL_ADDR"; then
  echo "[!] invalid FAIL address parsed: '$FAIL_ADDR'" >&2
  echo "$FAIL_INFO" >&2
  exit 1
fi

if ! validate_hex_privkey "$KEEP_KEY"; then
  echo "[!] invalid KEEP private key parsed: '$KEEP_KEY'" >&2
  echo "$KEEP_INFO" >&2
  exit 1
fi

if ! validate_hex_privkey "$FAIL_KEY"; then
  echo "[!] invalid FAIL private key parsed: '$FAIL_KEY'" >&2
  echo "$FAIL_INFO" >&2
  exit 1
fi

echo "[*] funder address: $FUNDER_ADDR"
FUNDER_BAL_BEFORE=$(cast balance "$FUNDER_ADDR" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0")
echo "[*] funder balance before funding: $FUNDER_BAL_BEFORE"

# -------- funding KEEP with safe nonce --------
KEEP_NONCE="$(get_safe_next_nonce "$FUNDER_ADDR" "$L2_RPC_URL")"
if [[ ! "$KEEP_NONCE" =~ ^[0-9]+$ ]]; then
  echo "[!] failed to determine safe nonce for KEEP funding: '$KEEP_NONCE'" >&2
  exit 1
fi

echo "[*] funding KEEP account: $KEEP_ADDR (nonce=$KEEP_NONCE)"
KEEP_FUND_OUT="$(send_funding_tx "$KEEP_ADDR" "$FUND_AMOUNT" "$KEEP_NONCE" 2>&1)" || {
  echo "[!] failed to fund KEEP account" >&2
  echo "$KEEP_FUND_OUT" >&2
  exit 1
}

KEEP_FUND_TX="$(jq -r '.transactionHash // empty' <<<"$KEEP_FUND_OUT" 2>/dev/null || true)"
if [[ -z "$KEEP_FUND_TX" ]]; then
  echo "[!] failed to parse KEEP funding tx hash" >&2
  echo "$KEEP_FUND_OUT" >&2
  exit 1
fi
if ! validate_tx_hash "$KEEP_FUND_TX"; then
  echo "[!] invalid KEEP funding tx hash: '$KEEP_FUND_TX'" >&2
  exit 1
fi

record_used_nonce "$KEEP_NONCE"

echo "[*] waiting for KEEP funding receipt: $KEEP_FUND_TX"
wait_for_receipt_success "$KEEP_FUND_TX" "$L2_RPC_URL"

# -------- funding FAIL with fresh safe nonce --------
FAIL_NONCE="$(get_safe_next_nonce "$FUNDER_ADDR" "$L2_RPC_URL")"
if [[ ! "$FAIL_NONCE" =~ ^[0-9]+$ ]]; then
  echo "[!] failed to determine safe nonce for FAIL funding: '$FAIL_NONCE'" >&2
  exit 1
fi

echo "[*] funding FAIL account: $FAIL_ADDR (nonce=$FAIL_NONCE)"
FAIL_FUND_OUT="$(send_funding_tx "$FAIL_ADDR" "$FUND_AMOUNT" "$FAIL_NONCE" 2>&1)" || {
  echo "[!] failed to fund FAIL account" >&2
  echo "$FAIL_FUND_OUT" >&2
  exit 1
}

FAIL_FUND_TX="$(jq -r '.transactionHash // empty' <<<"$FAIL_FUND_OUT" 2>/dev/null || true)"
if [[ -z "$FAIL_FUND_TX" ]]; then
  echo "[!] failed to parse FAIL funding tx hash" >&2
  echo "$FAIL_FUND_OUT" >&2
  exit 1
fi
if ! validate_tx_hash "$FAIL_FUND_TX"; then
  echo "[!] invalid FAIL funding tx hash: '$FAIL_FUND_TX'" >&2
  exit 1
fi

record_used_nonce "$FAIL_NONCE"

echo "[*] waiting for FAIL funding receipt: $FAIL_FUND_TX"
wait_for_receipt_success "$FAIL_FUND_TX" "$L2_RPC_URL"

FUND_AMOUNT_NUM="$(echo "$FUND_AMOUNT" | sed 's/[[:space:]]*ether$//I')"

echo "[*] waiting for KEEP balance to appear"
wait_for_min_balance "$KEEP_ADDR" "$L2_RPC_URL" "$FUND_AMOUNT_NUM"

echo "[*] waiting for FAIL balance to appear"
wait_for_min_balance "$FAIL_ADDR" "$L2_RPC_URL" "$FUND_AMOUNT_NUM"

echo "[*] checking KEEP balance"
KEEP_BAL=$(cast balance "$KEEP_ADDR" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0")
echo "$KEEP_BAL"

echo "[*] checking FAIL balance"
FAIL_BAL=$(cast balance "$FAIL_ADDR" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0")
echo "$FAIL_BAL"

cat > "$OUT_ENV" <<EOF
export L2_RPC_URL="$L2_RPC_URL"
export FUNDER_KEY="$FUNDER_KEY"

export KEY_KEEP="$KEEP_KEY"
export ADDR_KEEP="$KEEP_ADDR"

export KEY_FAIL="$FAIL_KEY"
export ADDR_FAIL="$FAIL_ADDR"

export TO_KEEP="0x2222222222222222222222222222222222222222"
export TO_FAIL="0x1111111111111111111111111111111111111111"
EOF

chmod 600 "$OUT_ENV"

echo
echo "[*] accounts prepared"
echo "KEEP address: $KEEP_ADDR"
echo "FAIL address: $FAIL_ADDR"
echo "[*] wrote env file: $OUT_ENV"
echo
echo "[*] next:"
echo "    source $OUT_ENV"