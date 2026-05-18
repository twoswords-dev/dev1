#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-azul-infra}"

rand() {
  openssl rand -base64 36 | tr -d '\n'
}

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# MinIO credentials
kubectl -n "${NAMESPACE}" create secret generic s3-keys \
  --from-literal=accesskey="${S3_ACCESS_KEY:-azulminio}" \
  --from-literal=secretkey="${S3_SECRET_KEY:-$(rand)}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic s3-backup-keys \
  --from-literal=accesskey="${S3_BACKUP_ACCESS_KEY:-azulbackup}" \
  --from-literal=secretkey="${S3_BACKUP_SECRET_KEY:-$(rand)}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Keycloak/Postgres credentials
kubectl -n "${NAMESPACE}" create secret generic keycloak \
  --from-literal=DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-$(rand)}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(rand)}" \
  --dry-run=client -o yaml | kubectl apply -f -

# OpenSearch credentials. These password values are intentionally dev defaults because
# the chart's default internal_users.yml includes matching commented examples.
kubectl -n "${NAMESPACE}" create secret generic azul-cluster-admincredentials \
  --from-literal=username="${OPENSEARCH_ADMIN_USER:-admin}" \
  --from-literal=password="${OPENSEARCH_ADMIN_PASSWORD:-adminpassword}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic azul-cluster-dashboardcredentials \
  --from-literal=username="${OPENSEARCH_DASHBOARD_USER:-kibanaserver}" \
  --from-literal=password="${OPENSEARCH_DASHBOARD_PASSWORD:-kibanaserverpassword}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created/updated Azul infra secrets in namespace ${NAMESPACE}."
echo "If you did not set KEYCLOAK_ADMIN_PASSWORD explicitly, retrieve it with:"
echo "kubectl -n ${NAMESPACE} get secret keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d; echo"
