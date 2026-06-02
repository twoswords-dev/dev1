#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-azul-app}"
INFRA_NAMESPACE="${INFRA_NAMESPACE:-azul-infra}"

rand() { openssl rand -base64 36 | tr -d '\n'; }

secret_value_or_default() {
  local secret_name="$1" key="$2" default_value="$3"
  kubectl -n "${APP_NAMESPACE}" get secret "${secret_name}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d || printf '%s' "${default_value}"
}

kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Reuse the MinIO keys created for the infra MinIO instance.
if kubectl -n "${INFRA_NAMESPACE}" get secret s3-keys >/dev/null 2>&1; then
  kubectl -n "${INFRA_NAMESPACE}" get secret s3-keys -o yaml \
    | sed "s/namespace: ${INFRA_NAMESPACE}/namespace: ${APP_NAMESPACE}/" \
    | kubectl apply -f -
else
  kubectl -n "${APP_NAMESPACE}" create secret generic s3-keys \
    --from-literal=accesskey="${S3_ACCESS_KEY:-azulminio}" \
    --from-literal=secretkey="${S3_SECRET_KEY:-$(rand)}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl -n "${APP_NAMESPACE}" create secret generic redis \
  --from-literal=redis-username="${REDIS_USERNAME:-default}" \
  --from-literal=redis-password="${REDIS_PASSWORD:-$(secret_value_or_default redis redis-password "$(rand)")}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Password must match the azul_writer hash configured in infra/values.yaml.
kubectl -n "${APP_NAMESPACE}" create secret generic metastore-creds \
  --from-literal=writer="${OPENSEARCH_AZUL_WRITER_PASSWORD:-$(secret_value_or_default metastore-creds writer AzulWriter1!)}" \
  --from-literal=jwt_signing_secret="${JWT_SIGNING_SECRET:-$(secret_value_or_default metastore-creds jwt_signing_secret "$(rand)")}" \
  --from-literal=opensearch_azul_security_password="${OPENSEARCH_AZUL_SECURITY_PASSWORD:-$(secret_value_or_default metastore-creds opensearch_azul_security_password AzulWriter1!)}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created/updated Azul app secrets in namespace ${APP_NAMESPACE}."

# Self-signed local ingress cert for azul.local if cert-manager is not issuing one.
if ! kubectl -n "${APP_NAMESPACE}" get secret azul-web-tls >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${tmpdir}/tls.key" \
    -out "${tmpdir}/tls.crt" \
    -subj '/CN=azul.local' \
    -addext 'subjectAltName=DNS:azul.local' >/dev/null 2>&1
  kubectl -n "${APP_NAMESPACE}" create secret tls azul-web-tls \
    --cert="${tmpdir}/tls.crt" --key="${tmpdir}/tls.key"
fi
