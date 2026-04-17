#!/usr/bin/env bash
set -euo pipefail

CASE_OVERRIDE_JSON="${1:-}"
WORK_DIR="${2:-./.case_tmp}"
CLUSTER_ENV="${CLUSTER_ENV:-./cluster.env}"

if [[ -f "$CLUSTER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CLUSTER_ENV"
fi

SEQUENCER_SSH_TARGET="${SEQUENCER_SSH_TARGET:-}"
SEQUENCER_CONFIG_PATH="${SEQUENCER_CONFIG_PATH:-/etc/nitro/sequencer_config.json}"
SEQUENCER_SERVICE="${SEQUENCER_SERVICE:-nitro-sequencer}"
SSH_OPTS="${SSH_OPTS:-}"

if [[ -z "$CASE_OVERRIDE_JSON" ]]; then
  echo "usage: $0 <case-override-json> [work-dir]" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd python3
need_cmd cp
need_cmd ssh
need_cmd scp
need_cmd mktemp

run_target_cmd() {
  local cmd="$1"
  if [[ -z "$SEQUENCER_SSH_TARGET" ]]; then
    bash -lc "$cmd"
  else
    ssh $SSH_OPTS "$SEQUENCER_SSH_TARGET" "bash -lc $(printf '%q' "$cmd")"
  fi
}

copy_from_target() {
  local src="$1"
  local dst="$2"
  if [[ -z "$SEQUENCER_SSH_TARGET" ]]; then
    cp "$src" "$dst"
  else
    scp $SSH_OPTS "$SEQUENCER_SSH_TARGET:$src" "$dst"
  fi
}

copy_to_target() {
  local src="$1"
  local dst="$2"
  if [[ -z "$SEQUENCER_SSH_TARGET" ]]; then
    cp "$src" "$dst"
  else
    scp $SSH_OPTS "$src" "$SEQUENCER_SSH_TARGET:$dst"
  fi
}

BASE_JSON="$WORK_DIR/sequencer_config.base.json"
OVERRIDE_JSON="$CASE_OVERRIDE_JSON"
MERGED_JSON="$WORK_DIR/sequencer_config.merged.json"
REMOTE_TMP="${SEQUENCER_CONFIG_PATH}.codex.$$"

if [[ ! -f "$BASE_JSON" ]]; then
  copy_from_target "$SEQUENCER_CONFIG_PATH" "$BASE_JSON"
fi

python3 ./merge_json.py "$BASE_JSON" "$OVERRIDE_JSON" "$MERGED_JSON"

copy_to_target "$MERGED_JSON" "$REMOTE_TMP"

run_target_cmd "cp '$REMOTE_TMP' '$SEQUENCER_CONFIG_PATH' && rm -f '$REMOTE_TMP' && systemctl restart '$SEQUENCER_SERVICE'"

echo "[*] applied config to ${SEQUENCER_CONFIG_PATH} and restarted ${SEQUENCER_SERVICE}"
