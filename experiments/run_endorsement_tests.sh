#!/usr/bin/env bash
set -euo pipefail

MATRIX_JSON="${1:-./experiment_matrix.json}"
OUT_DIR="${2:-./exp_out}"

ROOT_DIR="${ROOT_DIR:-$PWD}"
CASE_TMP_DIR="${ROOT_DIR}/.case_tmp"
FAULT_STATUS_DIR="${ROOT_DIR}/.fault_status"

L2_RPC_URL="${L2_RPC_URL:-http://127.0.0.1:8547}"

SEQ_CONTAINER="${SEQ_CONTAINER:-nitro-testnode-sequencer-1}"
ENDORSER_A="${ENDORSER_A:-nitro-testnode-endorser-a-1}"
ENDORSER_B="${ENDORSER_B:-nitro-testnode-endorser-b-1}"
ENDORSER_C="${ENDORSER_C:-nitro-testnode-endorser-c-1}"

TO_KEEP_DEFAULT="${TO_KEEP:-0x2222222222222222222222222222222222222222}"
TO_FAIL_DEFAULT="${TO_FAIL:-0x1111111111111111111111111111111111111111}"

# 预先准备好的账户池目录：每个 case 一个 .env
CASE_ACCOUNTS_DIR="${CASE_ACCOUNTS_DIR:-./accounts_pool}"

mkdir -p "$OUT_DIR" "$CASE_TMP_DIR" "$FAULT_STATUS_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd jq
need_cmd docker
need_cmd python3
need_cmd cast
need_cmd sed
need_cmd date
need_cmd bash
need_cmd cat
need_cmd grep

ensure_services_up() {
  docker compose up -d sequencer endorser-a endorser-b endorser-c >/dev/null
  sleep 5
}

safe_fault_name() {
  echo "$1" | sed 's#[/:, ]#_#g'
}

collect_case_logs_since() {
  local since_ts="$1"
  local case_dir="$2"

  docker logs --since "$since_ts" "$SEQ_CONTAINER" > "$case_dir/sequencer.log" 2>&1 || true
  docker logs --since "$since_ts" "$ENDORSER_A" > "$case_dir/endorser-a.log" 2>&1 || true
  docker logs --since "$since_ts" "$ENDORSER_B" > "$case_dir/endorser-b.log" 2>&1 || true
  docker logs --since "$since_ts" "$ENDORSER_C" > "$case_dir/endorser-c.log" 2>&1 || true
}

wait_for_rpc_ready() {
  local rpc_url="$1"
  local timeout_sec="${2:-90}"

  local start_ts now elapsed
  start_ts=$(date +%s)

  echo "[*] waiting for sequencer RPC ready: $rpc_url"

  while true; do
    if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1; then
      if cast chain-id --rpc-url "$rpc_url" >/dev/null 2>&1; then
        echo "[*] sequencer RPC is ready"
        return 0
      fi
    fi

    now=$(date +%s)
    elapsed=$((now - start_ts))
    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo "[!] sequencer RPC not ready within ${timeout_sec}s" >&2
      return 1
    fi
    sleep 2
  done
}

write_case_runtime_error() {
  local case_dir="$1"
  local msg="$2"
  echo "$msg" | tee "$case_dir/runtime_error.txt"
}

load_case_accounts_from_pool() {
  local case_name="$1"
  local case_dir="$2"

  local case_env="${CASE_ACCOUNTS_DIR}/${case_name}.env"
  if [[ ! -f "$case_env" ]]; then
    echo "[!] case accounts file not found: $case_env" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$case_env"

  if [[ -z "${KEY_KEEP:-}" || -z "${KEY_FAIL:-}" || -z "${ADDR_KEEP:-}" || -z "${ADDR_FAIL:-}" ]]; then
    echo "[!] invalid case accounts file: $case_env" >&2
    return 1
  fi

  echo "[*] using case KEEP address: $ADDR_KEEP"
  echo "[*] using case FAIL address: $ADDR_FAIL"

  cast balance "$ADDR_KEEP" --rpc-url "$L2_RPC_URL" > "$case_dir/keep_balance_before.txt" 2>/dev/null || true
  cast balance "$ADDR_FAIL" --rpc-url "$L2_RPC_URL" > "$case_dir/fail_balance_before.txt" 2>/dev/null || true
  cast nonce "$ADDR_KEEP" --rpc-url "$L2_RPC_URL" > "$case_dir/keep_nonce_before.txt" 2>/dev/null || true
  cast nonce "$ADDR_FAIL" --rpc-url "$L2_RPC_URL" > "$case_dir/fail_nonce_before.txt" 2>/dev/null || true

  export KEY_KEEP KEY_FAIL ADDR_KEEP ADDR_FAIL
  export TO_KEEP="$TO_KEEP_DEFAULT"
  export TO_FAIL="$TO_FAIL_DEFAULT"
}

run_case() {
  local case_json="$1"
  local case_file="$CASE_TMP_DIR/case.json"
  local override_json="$CASE_TMP_DIR/override.json"
  local name mode fault tx_total tps fail_ratio case_dir
  local case_start_ts fault_key fault_status_file

  echo "$case_json" > "$case_file"

  name=$(jq -r '.name' "$case_file")
  mode=$(jq -r '.mode' "$case_file")
  fault=$(jq -r '.fault' "$case_file")
  tx_total=$(jq -r '.tx_total' "$case_file")
  tps=$(jq -r '.tps' "$case_file")
  fail_ratio=$(jq -r '.fail_ratio' "$case_file")

  case_dir="$OUT_DIR/$name"
  mkdir -p "$case_dir"

  echo "[*] running case=$name mode=$mode fault=$fault"

  python3 ./write_case_config.py "$case_file" "$override_json"
  bash ./apply_case_config_to_volume.sh "$override_json" "$CASE_TMP_DIR"

  if ! wait_for_rpc_ready "$L2_RPC_URL" 90; then
    write_case_runtime_error "$case_dir" "sequencer RPC not ready after restart"
    case_start_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    collect_case_logs_since "$case_start_ts" "$case_dir"
    return 0
  fi

  if ! load_case_accounts_from_pool "$name" "$case_dir"; then
    write_case_runtime_error "$case_dir" "failed to load case-specific prepared accounts"
    return 0
  fi

  case_start_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "$case_start_ts" > "$case_dir/case_start_utc.txt"

  if ! bash ./fault_injector.sh apply "$fault" "$FAULT_STATUS_DIR"; then
    echo "[!] fault injection apply failed for case=$name fault=$fault" | tee "$case_dir/fault_apply_error.txt"
  fi

  fault_key="$(safe_fault_name "$fault")"
  fault_status_file="${FAULT_STATUS_DIR}/${fault_key}.status"
  if [[ -f "$fault_status_file" ]]; then
    cp "$fault_status_file" "$case_dir/fault_status.txt"
  fi

  bash ./send_workload.sh \
    --rpc "$L2_RPC_URL" \
    --tx-total "$tx_total" \
    --tps "$tps" \
    --fail-ratio "$fail_ratio" \
    --out "$case_dir/tx_results.csv" \
    --key-keep "$KEY_KEEP" \
    --key-fail "$KEY_FAIL" \
    --to-keep "$TO_KEEP" \
    --to-fail "$TO_FAIL"

  sleep 8

  collect_case_logs_since "$case_start_ts" "$case_dir"

  bash ./fault_injector.sh clear "$fault" "$FAULT_STATUS_DIR" || true

  if [[ -f "$fault_status_file" ]]; then
    cp "$fault_status_file" "$case_dir/fault_status_after_clear.txt"
  fi

  cast balance "$ADDR_KEEP" --rpc-url "$L2_RPC_URL" > "$case_dir/keep_balance_after.txt" 2>/dev/null || true
  cast balance "$ADDR_FAIL" --rpc-url "$L2_RPC_URL" > "$case_dir/fail_balance_after.txt" 2>/dev/null || true
  cast nonce "$ADDR_KEEP" --rpc-url "$L2_RPC_URL" > "$case_dir/keep_nonce_after.txt" 2>/dev/null || true
  cast nonce "$ADDR_FAIL" --rpc-url "$L2_RPC_URL" > "$case_dir/fail_nonce_after.txt" 2>/dev/null || true

  python3 ./extract_metrics.py \
    --case-name "$name" \
    --tx-csv "$case_dir/tx_results.csv" \
    --sequencer-log "$case_dir/sequencer.log" \
    --endorser-log "$case_dir/endorser-a.log" \
    --endorser-log "$case_dir/endorser-b.log" \
    --endorser-log "$case_dir/endorser-c.log" \
    --fault-status "$case_dir/fault_status.txt" \
    --out-json "$case_dir/summary.json" \
    --out-tsv "$case_dir/summary.tsv"
}

ensure_services_up

jq -c '.[]' "$MATRIX_JSON" | while read -r case_json; do
  run_case "$case_json"
done

echo "[*] all cases finished, output in $OUT_DIR"