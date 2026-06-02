#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-azul-app}"
TLS_SECRET="${TLS_SECRET:-azul-external-web-tls}"
# Sign azul.local with the same CA used by Keycloak/Rancher/OpenSearch/MinIO.
SIGNING_CA_NAMESPACE="${SIGNING_CA_NAMESPACE:-azul-infra}"
SIGNING_CA_SECRET="${SIGNING_CA_SECRET:-azul-infra-ca}"
CA_SECRET="${CA_SECRET:-azul-external-signing-ca}"

# Do not accidentally use bash's built-in HOSTNAME default (the machine name).
SYSTEM_HOSTNAME="$(hostname 2>/dev/null || true)"
if [[ -z "${AZUL_HOSTNAME:-}" ]]; then
  if [[ -n "${HOSTNAME:-}" && "${HOSTNAME}" != "$SYSTEM_HOSTNAME" ]]; then
    AZUL_HOSTNAME="$HOSTNAME"
  else
    AZUL_HOSTNAME="azul.local"
  fi
fi

OUT_DIR="${OUT_DIR:-/tmp/azul-external-web-tls}"
INGRESS_IP="${INGRESS_IP:-192.168.10.111}"
# Airgap/company PKI mode: set both to create the Kubernetes TLS secret from
# your provided certificate/key instead of generating a local homelab cert.
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

require_cmd base64
require_cmd kubectl
require_cmd openssl

mkdir -p "$OUT_DIR"
CA_KEY="$OUT_DIR/azul-infra-ca.key"
CA_CRT="$OUT_DIR/azul-infra-ca.crt"
BUNDLE_CRT="$OUT_DIR/azul-local-ca-bundle.crt"
LEAF_KEY="$OUT_DIR/${AZUL_HOSTNAME}.key"
LEAF_CSR="$OUT_DIR/${AZUL_HOSTNAME}.csr"
LEAF_CRT="$OUT_DIR/${AZUL_HOSTNAME}.crt"
EXT="$OUT_DIR/${AZUL_HOSTNAME}.ext"

if ! kubectl get namespace "$APP_NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace $APP_NAMESPACE does not exist; creating it"
  kubectl create namespace "$APP_NAMESPACE"
fi

if [[ -n "$TLS_CERT_FILE" || -n "$TLS_KEY_FILE" ]]; then
  if [[ -z "$TLS_CERT_FILE" || -z "$TLS_KEY_FILE" ]]; then
    echo "ERROR: set both TLS_CERT_FILE and TLS_KEY_FILE, or neither." >&2
    exit 1
  fi
  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
    echo "ERROR: TLS_CERT_FILE/TLS_KEY_FILE must point to existing files." >&2
    exit 1
  fi
  echo "Using provided company TLS certificate/key"
  cp "$TLS_CERT_FILE" "$LEAF_CRT"
  cp "$TLS_KEY_FILE" "$LEAF_KEY"
else
  if ! kubectl -n "$SIGNING_CA_NAMESPACE" get secret "$SIGNING_CA_SECRET" >/dev/null 2>&1; then
    echo "ERROR: signing CA secret not found: $SIGNING_CA_NAMESPACE/$SIGNING_CA_SECRET" >&2
    echo "Deploy/sync azul-infra first, then rerun this script." >&2
    exit 1
  fi

  echo "Using shared signing CA: $SIGNING_CA_NAMESPACE/$SIGNING_CA_SECRET"
  kubectl -n "$SIGNING_CA_NAMESPACE" get secret "$SIGNING_CA_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA_CRT"
  kubectl -n "$SIGNING_CA_NAMESPACE" get secret "$SIGNING_CA_SECRET" -o jsonpath='{.data.tls\.key}' | base64 -d > "$CA_KEY"
  chmod 600 "$CA_KEY"
  cp "$CA_CRT" "$BUNDLE_CRT"

  cat > "$EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${AZUL_HOSTNAME}
IP.1 = ${INGRESS_IP}
EOF

  openssl genrsa -out "$LEAF_KEY" 2048
  chmod 600 "$LEAF_KEY"
  openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" \
    -subj "/C=US/ST=Local/L=Homelab/O=Azul Local/OU=Azul/CN=${AZUL_HOSTNAME}"
  openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$LEAF_CRT" -days 825 -sha256 -extfile "$EXT"
fi

kubectl -n "$APP_NAMESPACE" create secret tls "$TLS_SECRET" \
  --cert="$LEAF_CRT" --key="$LEAF_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -f "$CA_CRT" && -f "$CA_KEY" ]]; then
  # Store a copy of the signing CA used for this leaf cert for traceability/reruns.
  kubectl -n "$APP_NAMESPACE" create secret generic "$CA_SECRET" \
    --from-file=ca.crt="$CA_CRT" \
    --from-file=ca.key="$CA_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

cat > "$OUT_DIR/install-azul-local-ca-bundle.ps1" <<PS1
param(
  [string]\$IngressIP = "${INGRESS_IP}",
  [string[]]\$Hostnames = @("azul.local", "keycloak.local", "rancher.local", "longhorn.local", "argocd.local", "opensearch-dashboards.local", "minio.local", "minio-api.local"),
  [string]\$CertificatePath = ".\\azul-local-ca-bundle.crt"
)
\$ErrorActionPreference = "Stop"
\$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not \$isAdmin) { throw "Run this script as Administrator." }
if (-not (Test-Path \$CertificatePath)) { throw "Certificate not found: \$CertificatePath" }
certutil -addstore -f Root \$CertificatePath | Out-Host
\$hostsPath = "\$env:SystemRoot\\System32\\drivers\\etc\\hosts"
\$hostsContent = Get-Content \$hostsPath -ErrorAction SilentlyContinue
foreach (\$name in \$Hostnames) {
  \$escapedName = [regex]::Escape(\$name)
  if (-not (\$hostsContent -match "(?m)^\\s*[^#\\s]+\\s+.*(?:^|\\s)\$escapedName(?:\\s|\`\$)")) {
    Add-Content -Path \$hostsPath -Value "\$IngressIP\`t\$name"
  }
}
Write-Host "Installed Azul local CA bundle and hosts entries. Restart your browser."
PS1

openssl x509 -in "$LEAF_CRT" -noout -subject -issuer -dates -ext subjectAltName

echo
cat <<EOF
Created/updated:
  Kubernetes TLS secret: $APP_NAMESPACE/$TLS_SECRET

Company cert mode:
  TLS_CERT_FILE=${TLS_CERT_FILE:-<unset>}
  TLS_KEY_FILE=${TLS_KEY_FILE:-<unset>}

Local homelab fallback CA:
  $SIGNING_CA_NAMESPACE/$SIGNING_CA_SECRET
Windows bundle is in:
  $OUT_DIR

Copy this folder to Windows, open PowerShell as Administrator, then run:
  Set-ExecutionPolicy -Scope Process Bypass
  .\\install-azul-local-ca-bundle.ps1 -IngressIP $INGRESS_IP
EOF
