#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Apply a company/browser-facing multi-SAN TLS certificate after Azul is working.

This script updates the Kubernetes TLS secrets used by the browser-facing
Ingresses and removes local cert-manager issuer annotations from those Ingresses
so cert-manager does not overwrite the manually supplied company certificate.

It does NOT replace internal service TLS for OpenSearch/Keycloak.

Required:
  TLS_CERT_FILE=/path/to/company-fullchain.crt
  TLS_KEY_FILE=/path/to/company.key

Optional environment variables:
  APP_NAMESPACE=azul-app
  INFRA_NAMESPACE=azul-infra
  AZUL_TLS_SECRET=azul-external-web-tls
  KEYCLOAK_TLS_SECRET=keycloak-tls
  DASHBOARDS_TLS_SECRET=dashboard-ingress-tls
  MINIO_TLS_SECRET=minio-tls
  MINIO_BACKUP_TLS_SECRET=minio-backup-tls
  OPENSEARCH_TLS_SECRET=opensearch-tls
  INCLUDE_MINIO_BACKUP=false
  INCLUDE_OPENSEARCH_INGRESS=false
  REMOVE_CERT_MANAGER_ANNOTATIONS=true

Examples:
  TLS_CERT_FILE=./company-fullchain.crt TLS_KEY_FILE=./company.key \
    scripts/post-working-external-cert.sh

  INCLUDE_MINIO_BACKUP=true TLS_CERT_FILE=./fullchain.crt TLS_KEY_FILE=./tls.key \
    scripts/post-working-external-cert.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APP_NAMESPACE="${APP_NAMESPACE:-azul-app}"
INFRA_NAMESPACE="${INFRA_NAMESPACE:-azul-infra}"

TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"

AZUL_TLS_SECRET="${AZUL_TLS_SECRET:-azul-external-web-tls}"
KEYCLOAK_TLS_SECRET="${KEYCLOAK_TLS_SECRET:-keycloak-tls}"
DASHBOARDS_TLS_SECRET="${DASHBOARDS_TLS_SECRET:-dashboard-ingress-tls}"
MINIO_TLS_SECRET="${MINIO_TLS_SECRET:-minio-tls}"
MINIO_BACKUP_TLS_SECRET="${MINIO_BACKUP_TLS_SECRET:-minio-backup-tls}"
OPENSEARCH_TLS_SECRET="${OPENSEARCH_TLS_SECRET:-opensearch-tls}"

INCLUDE_MINIO_BACKUP="${INCLUDE_MINIO_BACKUP:-false}"
INCLUDE_OPENSEARCH_INGRESS="${INCLUDE_OPENSEARCH_INGRESS:-false}"
REMOVE_CERT_MANAGER_ANNOTATIONS="${REMOVE_CERT_MANAGER_ANNOTATIONS:-true}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

require_cmd kubectl
require_cmd openssl

if [[ -z "$TLS_CERT_FILE" || -z "$TLS_KEY_FILE" ]]; then
  echo "ERROR: set TLS_CERT_FILE and TLS_KEY_FILE." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$TLS_CERT_FILE" ]]; then
  echo "ERROR: TLS_CERT_FILE not found: $TLS_CERT_FILE" >&2
  exit 1
fi

if [[ ! -f "$TLS_KEY_FILE" ]]; then
  echo "ERROR: TLS_KEY_FILE not found: $TLS_KEY_FILE" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CERT_PEM="$TMPDIR/cert.pem"
KEY_PUB="$TMPDIR/key.pub.pem"
CERT_PUB="$TMPDIR/cert.pub.pem"

# Accept either PEM or DER leaf/fullchain input. If PEM parse fails, try DER.
if openssl x509 -in "$TLS_CERT_FILE" -noout >/dev/null 2>&1; then
  cp "$TLS_CERT_FILE" "$CERT_PEM"
elif openssl x509 -inform DER -in "$TLS_CERT_FILE" -out "$CERT_PEM" >/dev/null 2>&1; then
  echo "Converted DER certificate to PEM for validation."
else
  echo "ERROR: TLS_CERT_FILE is not a valid PEM or DER X.509 certificate: $TLS_CERT_FILE" >&2
  exit 1
fi

openssl x509 -in "$CERT_PEM" -pubkey -noout | openssl pkey -pubin -outform pem > "$CERT_PUB"
openssl pkey -in "$TLS_KEY_FILE" -pubout -outform pem > "$KEY_PUB"

CERT_HASH="$(sha256sum "$CERT_PUB" | awk '{print $1}')"
KEY_HASH="$(sha256sum "$KEY_PUB" | awk '{print $1}')"

if [[ "$CERT_HASH" != "$KEY_HASH" ]]; then
  echo "ERROR: certificate and private key do not match." >&2
  echo "certificate public key sha256: $CERT_HASH" >&2
  echo "private key public key sha256: $KEY_HASH" >&2
  exit 1
fi

echo "Certificate/key match verified."
echo "Certificate summary:"
openssl x509 -in "$CERT_PEM" -noout -subject -issuer -dates -ext subjectAltName || true

apply_tls_secret() {
  local namespace="$1" secret="$2"
  echo "Applying TLS secret $namespace/$secret ..."
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$namespace" create secret tls "$secret" \
    --cert="$TLS_CERT_FILE" \
    --key="$TLS_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
}

remove_cm_annotations() {
  local namespace="$1" ingress="$2"
  if kubectl -n "$namespace" get ingress "$ingress" >/dev/null 2>&1; then
    echo "Removing local cert-manager annotations from ingress $namespace/$ingress ..."
    kubectl -n "$namespace" annotate ingress "$ingress" \
      cert-manager.io/issuer- \
      cert-manager.io/cluster-issuer- \
      --overwrite >/dev/null || true
  else
    echo "Ingress $namespace/$ingress not found; skipping annotation removal."
  fi
}

apply_tls_secret "$APP_NAMESPACE" "$AZUL_TLS_SECRET"
apply_tls_secret "$INFRA_NAMESPACE" "$KEYCLOAK_TLS_SECRET"
apply_tls_secret "$INFRA_NAMESPACE" "$DASHBOARDS_TLS_SECRET"
apply_tls_secret "$INFRA_NAMESPACE" "$MINIO_TLS_SECRET"

if [[ "$INCLUDE_MINIO_BACKUP" == "true" ]]; then
  apply_tls_secret "$INFRA_NAMESPACE" "$MINIO_BACKUP_TLS_SECRET"
fi

if [[ "$INCLUDE_OPENSEARCH_INGRESS" == "true" ]]; then
  apply_tls_secret "$INFRA_NAMESPACE" "$OPENSEARCH_TLS_SECRET"
fi

if [[ "$REMOVE_CERT_MANAGER_ANNOTATIONS" == "true" ]]; then
  # Azul ingress does not normally have cert-manager annotations, but removing
  # them is harmless if someone added one later.
  remove_cm_annotations "$APP_NAMESPACE" web
  remove_cm_annotations "$INFRA_NAMESPACE" keycloak
  remove_cm_annotations "$INFRA_NAMESPACE" azul-opensearch-dashboards
  remove_cm_annotations "$INFRA_NAMESPACE" s3-store-minio
  remove_cm_annotations "$INFRA_NAMESPACE" s3-store-minio-api
  remove_cm_annotations "$INFRA_NAMESPACE" minio
  remove_cm_annotations "$INFRA_NAMESPACE" minio-api
  if [[ "$INCLUDE_MINIO_BACKUP" == "true" ]]; then
    remove_cm_annotations "$INFRA_NAMESPACE" s3-store-minio-backup
    remove_cm_annotations "$INFRA_NAMESPACE" s3-store-minio-backup-api
    remove_cm_annotations "$INFRA_NAMESPACE" minio-backup
    remove_cm_annotations "$INFRA_NAMESPACE" minio-backup-api
  fi
  if [[ "$INCLUDE_OPENSEARCH_INGRESS" == "true" ]]; then
    remove_cm_annotations "$INFRA_NAMESPACE" azul-opensearch
  fi
fi

cat <<EOF

Done.

Updated browser-facing TLS secrets:
  $APP_NAMESPACE/$AZUL_TLS_SECRET
  $INFRA_NAMESPACE/$KEYCLOAK_TLS_SECRET
  $INFRA_NAMESPACE/$DASHBOARDS_TLS_SECRET
  $INFRA_NAMESPACE/$MINIO_TLS_SECRET
EOF

if [[ "$INCLUDE_MINIO_BACKUP" == "true" ]]; then
  echo "  $INFRA_NAMESPACE/$MINIO_BACKUP_TLS_SECRET"
fi
if [[ "$INCLUDE_OPENSEARCH_INGRESS" == "true" ]]; then
  echo "  $INFRA_NAMESPACE/$OPENSEARCH_TLS_SECRET"
fi

cat <<'EOF'

Verify with SNI, for example:
  for host in azul.local keycloak.local opensearch-dashboards.local minio.local minio-api.local; do
    echo "=== $host ==="
    openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
  done

This script does not modify internal service TLS or CA bundles.
EOF
