#!/usr/bin/env bash
set -euo pipefail

CASE_OVERRIDE_JSON="${1:-}"
WORK_DIR="${2:-./.case_tmp}"

CONFIG_VOLUME="${CONFIG_VOLUME:-nitro-testnode_config}"
SEQUENCER_CONTAINER="${SEQUENCER_CONTAINER:-nitro-testnode-sequencer-1}"

if [[ -z "$CASE_OVERRIDE_JSON" ]]; then
  echo "usage: $0 <case-override-json> [work-dir]" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd docker
need_cmd python3

HELPER_NAME="nitro-config-helper-$$"
BASE_JSON="$WORK_DIR/sequencer_config.base.json"
OVERRIDE_JSON="$CASE_OVERRIDE_JSON"
MERGED_JSON="$WORK_DIR/sequencer_config.merged.json"

cleanup() {
  docker rm -f "$HELPER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker create --name "$HELPER_NAME" -v "${CONFIG_VOLUME}:/config" alpine:3.19 sleep 600 >/dev/null

# 首次时从 volume 里导出当前配置，作为基线备份
if [[ ! -f "$BASE_JSON" ]]; then
  docker cp "${HELPER_NAME}:/config/sequencer_config.json" "$BASE_JSON"
fi

python3 ./merge_json.py "$BASE_JSON" "$OVERRIDE_JSON" "$MERGED_JSON"

docker cp "$MERGED_JSON" "${HELPER_NAME}:/config/sequencer_config.json"

docker restart "$SEQUENCER_CONTAINER" >/dev/null

echo "[*] applied config to volume ${CONFIG_VOLUME} and restarted ${SEQUENCER_CONTAINER}"