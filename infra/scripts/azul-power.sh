#!/usr/bin/env bash
set -euo pipefail

# Scale Azul app + infra down/up without deleting PVCs or namespaces.
# Usage:
#   scripts/azul-power.sh off
#   scripts/azul-power.sh on
#   scripts/azul-power.sh status
#
# Override namespaces if needed:
#   AZUL_APP_NS=azul-app AZUL_INFRA_NS=azul-infra scripts/azul-power.sh off

APP_NS="${AZUL_APP_NS:-azul-app}"
INFRA_NS="${AZUL_INFRA_NS:-azul-infra}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AZUL_POWER_STATE_DIR:-${SCRIPT_DIR}/.azul-power-state}"
REPLICAS_FILE="${STATE_DIR}/replicas.tsv"

usage() {
  echo "Usage: $0 {off|on|status}" >&2
  exit 2
}

need_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
}

ns_exists() {
  kubectl get ns "$1" >/dev/null 2>&1
}

save_workload_replicas() {
  local ns="$1"
  kubectl -n "$ns" get deploy -o jsonpath='{range .items[*]}deployment{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null >> "$REPLICAS_FILE" || true
  kubectl -n "$ns" get sts -o jsonpath='{range .items[*]}statefulset{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null >> "$REPLICAS_FILE" || true
}

backup_custom_resources() {
  local ns="$1"
  kubectl -n "$ns" get kafkanodepool.kafka.strimzi.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\n"}{end}' > "${STATE_DIR}/kafkanodepools-${ns}.tsv" 2>/dev/null || true
  kubectl -n "$ns" get opensearchcluster.opensearch.org -o json | python3 -c 'import json,sys; o=json.load(sys.stdin); [print(i["metadata"]["name"], p.get("component", n), p.get("replicas", 0), sep="\t") for i in o.get("items", []) for n,p in enumerate(i.get("spec",{}).get("nodePools", []))]' > "${STATE_DIR}/opensearchclusters-org-${ns}.tsv" 2>/dev/null || true
  kubectl -n "$ns" get opensearchcluster.opensearch.opster.io -o json | python3 -c 'import json,sys; o=json.load(sys.stdin); [print(i["metadata"]["name"], p.get("component", n), p.get("replicas", 0), sep="\t") for i in o.get("items", []) for n,p in enumerate(i.get("spec",{}).get("nodePools", []))]' > "${STATE_DIR}/opensearchclusters-opster-${ns}.tsv" 2>/dev/null || true
}

patch_kafkanodepools() {
  local ns="$1" replicas="$2"
  local names
  names="$(kubectl -n "$ns" get kafkanodepool.kafka.strimzi.io -o name 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0
  while read -r name; do
    [[ -n "$name" ]] || continue
    kubectl -n "$ns" patch "$name" --type=merge -p "{\"spec\":{\"replicas\":${replicas}}}" >/dev/null
  done <<< "$names"
}

patch_opensearchclusters_zero() {
  local ns="$1" resource="$2"
  local names patch
  names="$(kubectl -n "$ns" get "$resource" -o name 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0
  while read -r name; do
    [[ -n "$name" ]] || continue
    patch="$(kubectl -n "$ns" get "$name" -o json | python3 -c 'import json,sys; o=json.load(sys.stdin); pools=o.get("spec",{}).get("nodePools",[]); print(json.dumps([{"op":"replace","path":"/spec/nodePools/%d/replicas"%i,"value":0} for i,_ in enumerate(pools)]))')"
    [[ "$patch" == "[]" ]] || kubectl -n "$ns" patch "$name" --type=json -p "$patch" >/dev/null
  done <<< "$names"
}

backup_hpas() {
  local ns="$1"
  if kubectl -n "$ns" get hpa >/dev/null 2>&1; then
    kubectl -n "$ns" get hpa -o yaml > "${STATE_DIR}/hpa-${ns}.yaml" 2>/dev/null || true
  fi
}

scale_all_workloads() {
  local ns="$1" replicas="$2"
  kubectl -n "$ns" scale deployment --all --replicas="$replicas" --timeout=60s 2>/dev/null || true
  kubectl -n "$ns" scale statefulset --all --replicas="$replicas" --timeout=60s 2>/dev/null || true
}

turn_off() {
  mkdir -p "$STATE_DIR"
  : > "$REPLICAS_FILE"

  echo "Saving current replica counts in ${STATE_DIR}"
  ns_exists "$APP_NS" && { save_workload_replicas "$APP_NS"; backup_hpas "$APP_NS"; }
  ns_exists "$INFRA_NS" && {
    save_workload_replicas "$INFRA_NS"
    backup_hpas "$INFRA_NS"
    backup_custom_resources "$INFRA_NS"
  }

  echo "Turning off Azul app namespace: ${APP_NS}"
  if ns_exists "$APP_NS"; then
    kubectl -n "$APP_NS" delete hpa --all --ignore-not-found=true
    scale_all_workloads "$APP_NS" 0
  fi

  echo "Turning off Azul infra namespace: ${INFRA_NS}"
  if ns_exists "$INFRA_NS"; then
    kubectl -n "$INFRA_NS" delete hpa --all --ignore-not-found=true

    # Ask operators to shut down managed data-plane pods before stopping the operators.
    patch_kafkanodepools "$INFRA_NS" 0
    patch_opensearchclusters_zero "$INFRA_NS" "opensearchcluster.opensearch.org"
    patch_opensearchclusters_zero "$INFRA_NS" "opensearchcluster.opensearch.opster.io"

    echo "Waiting briefly for operator-managed pods to terminate..."
    sleep 10
    scale_all_workloads "$INFRA_NS" 0
  fi

  echo "Done. PVCs, Services, Ingresses, Secrets, and ConfigMaps were left intact."
}

turn_on() {
  [[ -f "$REPLICAS_FILE" ]] || { echo "No state file found at ${REPLICAS_FILE}; run '$0 off' first." >&2; exit 1; }

  echo "Turning Azul infra back on first: ${INFRA_NS}"
  while IFS=$'\t' read -r kind name replicas; do
    [[ -n "${kind:-}" && -n "${name:-}" && -n "${replicas:-}" ]] || continue
    case "$kind" in
      deployment|statefulset)
        [[ "$name" =~ ^(azul-infra-opensearch-operator|strimzi-cluster-operator|postgres|s3-store-minio|keycloak|azul-opensearch-dashboards|azul-kafka-.*) ]] || continue
        kubectl -n "$INFRA_NS" scale "$kind/$name" --replicas="$replicas" --timeout=60s 2>/dev/null || true
        ;;
    esac
  done < "$REPLICAS_FILE"

  # Restore operator-managed CR replica counts saved by 'off'.
  if [[ -f "${STATE_DIR}/kafkanodepools-${INFRA_NS}.tsv" ]]; then
    while IFS=$'\t' read -r name replicas; do
      [[ -n "${name:-}" && -n "${replicas:-}" ]] || continue
      kubectl -n "$INFRA_NS" patch "kafkanodepool.kafka.strimzi.io/$name" --type=merge -p "{\"spec\":{\"replicas\":${replicas}}}" >/dev/null 2>&1 || true
    done < "${STATE_DIR}/kafkanodepools-${INFRA_NS}.tsv"
  fi
  for tuple in "opensearchcluster.opensearch.org:${STATE_DIR}/opensearchclusters-org-${INFRA_NS}.tsv" "opensearchcluster.opensearch.opster.io:${STATE_DIR}/opensearchclusters-opster-${INFRA_NS}.tsv"; do
    resource="${tuple%%:*}"
    file="${tuple#*:}"
    [[ -f "$file" ]] || continue
    while IFS=$'\t' read -r name component replicas; do
      [[ -n "${name:-}" && -n "${component:-}" && -n "${replicas:-}" ]] || continue
      idx="$(kubectl -n "$INFRA_NS" get "$resource/$name" -o json 2>/dev/null | python3 -c 'import json,sys; o=json.load(sys.stdin); c=sys.argv[1]; print(next((i for i,p in enumerate(o.get("spec",{}).get("nodePools",[])) if str(p.get("component", i))==c), ""))' "$component")"
      [[ -n "$idx" ]] || continue
      kubectl -n "$INFRA_NS" patch "$resource/$name" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/nodePools/${idx}/replicas\",\"value\":${replicas}}]" >/dev/null 2>&1 || true
    done < "$file"
  done
  [[ -f "${STATE_DIR}/hpa-${INFRA_NS}.yaml" ]] && kubectl -n "$INFRA_NS" apply -f "${STATE_DIR}/hpa-${INFRA_NS}.yaml" >/dev/null 2>&1 || true

  echo "Turning Azul app back on: ${APP_NS}"
  while IFS=$'\t' read -r kind name replicas; do
    [[ -n "${kind:-}" && -n "${name:-}" && -n "${replicas:-}" ]] || continue
    case "$kind" in
      deployment|statefulset)
        kubectl -n "$APP_NS" get "$kind/$name" >/dev/null 2>&1 || continue
        kubectl -n "$APP_NS" scale "$kind/$name" --replicas="$replicas" --timeout=60s 2>/dev/null || true
        ;;
    esac
  done < "$REPLICAS_FILE"

  [[ -f "${STATE_DIR}/hpa-${APP_NS}.yaml" ]] && kubectl -n "$APP_NS" apply -f "${STATE_DIR}/hpa-${APP_NS}.yaml" >/dev/null 2>&1 || true

  echo "Done. Use '$0 status' to watch readiness."
}

status() {
  for ns in "$INFRA_NS" "$APP_NS"; do
    echo "--- ${ns} ---"
    if ns_exists "$ns"; then
      kubectl -n "$ns" get deploy,sts,hpa,kafkanodepool.kafka.strimzi.io,opensearchcluster.opensearch.org,opensearchcluster.opensearch.opster.io 2>/dev/null || \
        kubectl -n "$ns" get deploy,sts,hpa 2>/dev/null || true
    else
      echo "namespace not found"
    fi
  done
}

need_kubectl
case "${1:-}" in
  off) turn_off ;;
  on) turn_on ;;
  status) status ;;
  *) usage ;;
esac
