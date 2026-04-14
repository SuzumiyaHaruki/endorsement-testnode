#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
FAULT="${2:-none}"
STATUS_DIR="${3:-./.fault_status}"

mkdir -p "$STATUS_DIR"

safe_fault_name() {
  echo "$1" | sed 's#[/:, ]#_#g'
}

FAULT_KEY="$(safe_fault_name "$FAULT")"
STATUS_FILE="$STATUS_DIR/${FAULT_KEY}.status"

write_status() {
  local status="$1"
  local msg="${2:-}"
  cat > "$STATUS_FILE" <<EOF
status=$status
fault=$FAULT
message=$msg
timestamp=$(date +%s)
EOF
}

clear_status() {
  rm -f "$STATUS_FILE"
}

container_has_tc() {
  local container="$1"
  docker exec -u 0 "$container" sh -c "command -v tc >/dev/null 2>&1"
}

apply_delay() {
  local container="$1"
  local delay="$2"
  local ms="${delay%ms}"

  if ! container_has_tc "$container"; then
    write_status "failed" "container ${container} does not have tc installed"
    echo "[!] fault injection failed: container ${container} does not have tc installed" >&2
    return 10
  fi

  docker exec -u 0 "$container" sh -c "tc qdisc del dev eth0 root 2>/dev/null || true"
  docker exec -u 0 "$container" sh -c "tc qdisc add dev eth0 root netem delay ${ms}ms"

  write_status "applied" "delay ${ms}ms applied to ${container}"
  echo "[*] applied delay fault: ${container} ${ms}ms"
}

clear_delay() {
  local container="$1"

  if container_has_tc "$container"; then
    docker exec -u 0 "$container" sh -c "tc qdisc del dev eth0 root 2>/dev/null || true" || true
  fi

  write_status "cleared" "delay cleared for ${container}"
  echo "[*] cleared delay fault for ${container}"
}

apply_down() {
  local container="$1"
  docker stop "$container" >/dev/null
  write_status "applied" "container ${container} stopped"
  echo "[*] applied down fault: stopped ${container}"
}

clear_down() {
  local container="$1"
  docker start "$container" >/dev/null || true
  write_status "cleared" "container ${container} started"
  echo "[*] cleared down fault for ${container}"
}

if [[ "$FAULT" == "none" ]]; then
  write_status "noop" "no fault requested"
  exit 0
fi

if [[ "$ACTION" == "apply" ]]; then
  clear_status

  if [[ "$FAULT" =~ ^delay:([^:]+):([^:]+)$ ]]; then
    apply_delay "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    exit $?
  fi

  if [[ "$FAULT" =~ ^down:(.+)$ ]]; then
    IFS=',' read -ra ARR <<< "${BASH_REMATCH[1]}"
    for c in "${ARR[@]}"; do
      apply_down "$c"
    done
    exit 0
  fi

  write_status "failed" "unsupported apply fault syntax"
  echo "unsupported apply fault: $FAULT" >&2
  exit 2
fi

if [[ "$ACTION" == "clear" ]]; then
  if [[ "$FAULT" =~ ^delay:([^:]+):([^:]+)$ ]]; then
    clear_delay "${BASH_REMATCH[1]}"
    exit 0
  fi

  if [[ "$FAULT" =~ ^down:(.+)$ ]]; then
    IFS=',' read -ra ARR <<< "${BASH_REMATCH[1]}"
    for c in "${ARR[@]}"; do
      clear_down "$c"
    done
    exit 0
  fi

  write_status "failed" "unsupported clear fault syntax"
  echo "unsupported clear fault: $FAULT" >&2
  exit 2
fi

write_status "failed" "unsupported action ${ACTION}"
echo "unsupported action/fault: $ACTION $FAULT" >&2
exit 2