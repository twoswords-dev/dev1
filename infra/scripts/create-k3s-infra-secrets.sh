#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-azul-infra}"

rand() {
  openssl rand -base64 36 | tr -d '\n'
}

# Preserve existing generated secret values so repeated runs do not break services
# that initialized persistent data with the original password, such as Postgres.
secret_value_or_default() {
  local secret_name="$1"
  local key="$2"
  local default_value="$3"

  kubectl -n "${NAMESPACE}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d || printf '%s' "${default_value}"
}

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

S3_ACCESS_KEY="${S3_ACCESS_KEY:-$(secret_value_or_default s3-keys accesskey azulminio)}"
S3_SECRET_KEY="${S3_SECRET_KEY:-$(secret_value_or_default s3-keys secretkey "$(rand)")}"
S3_BACKUP_ACCESS_KEY="${S3_BACKUP_ACCESS_KEY:-$(secret_value_or_default s3-backup-keys accesskey azulbackup)}"
S3_BACKUP_SECRET_KEY="${S3_BACKUP_SECRET_KEY:-$(secret_value_or_default s3-backup-keys secretkey "$(rand)")}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-$(secret_value_or_default keycloak DB_PASSWORD "$(rand)")}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(secret_value_or_default keycloak KEYCLOAK_ADMIN_PASSWORD "$(rand)")}"

# MinIO credentials
kubectl -n "${NAMESPACE}" create secret generic s3-keys \
  --from-literal=accesskey="${S3_ACCESS_KEY}" \
  --from-literal=secretkey="${S3_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic s3-backup-keys \
  --from-literal=accesskey="${S3_BACKUP_ACCESS_KEY}" \
  --from-literal=secretkey="${S3_BACKUP_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Keycloak/Postgres credentials
kubectl -n "${NAMESPACE}" create secret generic keycloak \
  --from-literal=DB_PASSWORD="${KEYCLOAK_DB_PASSWORD}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
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
