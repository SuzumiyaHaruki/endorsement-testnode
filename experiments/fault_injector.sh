#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
FAULT="${2:-none}"
STATUS_DIR="${3:-./.fault_status}"
CLUSTER_ENV="${CLUSTER_ENV:-./cluster.env}"

if [[ -f "$CLUSTER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CLUSTER_ENV"
fi

SSH_OPTS="${SSH_OPTS:-}"

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

node_ssh_target() {
  case "$1" in
    sequencer) echo "${SEQUENCER_SSH_TARGET:-}" ;;
    endorser-a) echo "${ENDORSER_A_SSH_TARGET:-}" ;;
    endorser-b) echo "${ENDORSER_B_SSH_TARGET:-}" ;;
    endorser-c) echo "${ENDORSER_C_SSH_TARGET:-}" ;;
    *) return 1 ;;
  esac
}

node_service() {
  case "$1" in
    sequencer) echo "${SEQUENCER_SERVICE:-nitro-sequencer}" ;;
    endorser-a) echo "${ENDORSER_A_SERVICE:-nitro-endorser-a}" ;;
    endorser-b) echo "${ENDORSER_B_SERVICE:-nitro-endorser-b}" ;;
    endorser-c) echo "${ENDORSER_C_SERVICE:-nitro-endorser-c}" ;;
    *) return 1 ;;
  esac
}

node_iface() {
  case "$1" in
    sequencer) echo "${SEQUENCER_NET_IFACE:-eth0}" ;;
    endorser-a) echo "${ENDORSER_A_NET_IFACE:-eth0}" ;;
    endorser-b) echo "${ENDORSER_B_NET_IFACE:-eth0}" ;;
    endorser-c) echo "${ENDORSER_C_NET_IFACE:-eth0}" ;;
    *) return 1 ;;
  esac
}

run_node_cmd() {
  local node="$1"
  local cmd="$2"
  local target

  target="$(node_ssh_target "$node")"
  if [[ -z "$target" ]]; then
    bash -lc "$cmd"
  else
    ssh $SSH_OPTS "$target" "bash -lc $(printf '%q' "$cmd")"
  fi
}

node_has_tc() {
  local node="$1"
  run_node_cmd "$node" "command -v tc >/dev/null 2>&1"
}

apply_delay() {
  local node="$1"
  local delay="$2"
  local ms="${delay%ms}"
  local iface

  iface="$(node_iface "$node")"

  if ! node_has_tc "$node"; then
    write_status "failed" "node ${node} does not have tc installed"
    echo "[!] fault injection failed: node ${node} does not have tc installed" >&2
    return 10
  fi

  run_node_cmd "$node" "tc qdisc del dev '$iface' root 2>/dev/null || true"
  run_node_cmd "$node" "tc qdisc add dev '$iface' root netem delay ${ms}ms"

  write_status "applied" "delay ${ms}ms applied to ${node}"
  echo "[*] applied delay fault: ${node} ${ms}ms"
}

clear_delay() {
  local node="$1"
  local iface

  iface="$(node_iface "$node")"

  if node_has_tc "$node"; then
    run_node_cmd "$node" "tc qdisc del dev '$iface' root 2>/dev/null || true" || true
  fi

  write_status "cleared" "delay cleared for ${node}"
  echo "[*] cleared delay fault for ${node}"
}

apply_down() {
  local node="$1"
  local service

  service="$(node_service "$node")"
  run_node_cmd "$node" "systemctl stop '$service'"
  write_status "applied" "service ${service} stopped on ${node}"
  echo "[*] applied down fault: stopped ${service} on ${node}"
}

clear_down() {
  local node="$1"
  local service

  service="$(node_service "$node")"
  run_node_cmd "$node" "systemctl start '$service'" || true
  write_status "cleared" "service ${service} started on ${node}"
  echo "[*] cleared down fault for ${node}"
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
    for node in "${ARR[@]}"; do
      apply_down "$node"
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
    for node in "${ARR[@]}"; do
      clear_down "$node"
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
