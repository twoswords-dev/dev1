#!/usr/bin/env bash
set -euo pipefail

# Start/stop a small k3s cluster from the master node.
#
# Usage:
#   scripts/k3s-cluster-power.sh stop
#   scripts/k3s-cluster-power.sh start
#   scripts/k3s-cluster-power.sh restart
#   scripts/k3s-cluster-power.sh status
#
# Override workers when kubectl cannot discover them, or on first start after a full stop:
#   K3S_WORKERS="192.168.10.112 192.168.10.113" scripts/k3s-cluster-power.sh start
#
# Optional knobs:
#   SSH_USER=pi                      # defaults to current user
#   SSH_OPTS="-o BatchMode=yes"       # extra ssh options
#   MASTER_SERVICE=k3s               # default master systemd unit
#   WORKER_SERVICE=k3s-agent         # default worker systemd unit
#   SKIP_AZUL_POWER=1                # do not scale Azul workloads off/on

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${K3S_POWER_STATE_DIR:-${SCRIPT_DIR}/.k3s-cluster-power-state}"
WORKERS_FILE="${STATE_DIR}/workers.txt"

SSH_USER="${SSH_USER:-$(id -un)}"
SSH_OPTS="${SSH_OPTS:-}"
MASTER_SERVICE="${MASTER_SERVICE:-k3s}"
WORKER_SERVICE="${WORKER_SERVICE:-k3s-agent}"
AZUL_POWER_SCRIPT="${AZUL_POWER_SCRIPT:-${SCRIPT_DIR}/../infra/scripts/azul-power.sh}"

usage() {
  echo "Usage: $0 {start|stop|restart|status}" >&2
  exit 2
}

run_sudo() {
  sudo "$@"
}

ssh_worker() {
  local host="$1"
  shift
  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@"
}

master_name() {
  hostname -s
}

save_workers() {
  mkdir -p "$STATE_DIR"
  if [[ -n "${K3S_WORKERS:-}" ]]; then
    tr ' ' '\n' <<< "$K3S_WORKERS" | sed '/^$/d' > "$WORKERS_FILE"
    return 0
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    local master short fqdn
    master="$(master_name)"
    fqdn="$(hostname -f 2>/dev/null || hostname)"
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep -Ev "^(${master}|${fqdn})$" > "$WORKERS_FILE" || true
  fi
}

load_workers() {
  if [[ -n "${K3S_WORKERS:-}" ]]; then
    tr ' ' '\n' <<< "$K3S_WORKERS" | sed '/^$/d'
  elif [[ -s "$WORKERS_FILE" ]]; then
    cat "$WORKERS_FILE"
  else
    return 0
  fi
}

azul_off() {
  [[ "${SKIP_AZUL_POWER:-0}" == "1" ]] && return 0
  [[ -x "$AZUL_POWER_SCRIPT" ]] || return 0
  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    "$AZUL_POWER_SCRIPT" off || true
  fi
}

azul_on() {
  [[ "${SKIP_AZUL_POWER:-0}" == "1" ]] && return 0
  [[ -x "$AZUL_POWER_SCRIPT" ]] || return 0
  "$AZUL_POWER_SCRIPT" on || true
}

stop_cluster() {
  echo "Saving worker list..."
  save_workers

  echo "Scaling Azul workloads down, if available..."
  azul_off

  echo "Stopping k3s agents on workers..."
  while read -r worker; do
    [[ -n "$worker" ]] || continue
    echo "- ${worker}: stopping ${WORKER_SERVICE}"
    ssh_worker "$worker" "sudo systemctl stop '${WORKER_SERVICE}'" || true
  done < <(load_workers)

  echo "Stopping master service: ${MASTER_SERVICE}"
  run_sudo systemctl stop "$MASTER_SERVICE"
  echo "Cluster stopped. Worker list saved at ${WORKERS_FILE}"
}

start_cluster() {
  echo "Starting master service: ${MASTER_SERVICE}"
  run_sudo systemctl start "$MASTER_SERVICE"

  echo "Waiting for Kubernetes API..."
  for _ in {1..60}; do
    if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  echo "Starting k3s agents on workers..."
  while read -r worker; do
    [[ -n "$worker" ]] || continue
    echo "- ${worker}: starting ${WORKER_SERVICE}"
    ssh_worker "$worker" "sudo systemctl start '${WORKER_SERVICE}'" || true
  done < <(load_workers)

  echo "Waiting for nodes to report Ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=5m || true

  echo "Scaling Azul workloads up, if prior state exists..."
  azul_on
  echo "Cluster started."
}

status_cluster() {
  echo "--- master ${MASTER_SERVICE} ---"
  systemctl is-active "$MASTER_SERVICE" || true

  echo "--- workers ${WORKER_SERVICE} ---"
  while read -r worker; do
    [[ -n "$worker" ]] || continue
    printf '%s: ' "$worker"
    ssh_worker "$worker" "systemctl is-active '${WORKER_SERVICE}'" || true
  done < <(load_workers)

  echo "--- kubernetes nodes ---"
  kubectl get nodes -o wide 2>/dev/null || true
}

case "${1:-}" in
  stop) stop_cluster ;;
  start) start_cluster ;;
  restart) stop_cluster; start_cluster ;;
  status) status_cluster ;;
  *) usage ;;
esac
