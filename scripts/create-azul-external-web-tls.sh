#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-azul-app}"
TLS_SECRET="${TLS_SECRET:-azul-external-web-tls}"
CA_SECRET="${CA_SECRET:-azul-external-root-ca}"
HOSTNAME="${HOSTNAME:-azul.local}"
OUT_DIR="${OUT_DIR:-/tmp/azul-external-web-tls}"
INGRESS_IP="${INGRESS_IP:-192.168.10.111}"

mkdir -p "$OUT_DIR"
ROOT_KEY="$OUT_DIR/azul-local-root-ca.key"
ROOT_CRT="$OUT_DIR/azul-local-root-ca.crt"
LEAF_KEY="$OUT_DIR/${HOSTNAME}.key"
LEAF_CSR="$OUT_DIR/${HOSTNAME}.csr"
LEAF_CRT="$OUT_DIR/${HOSTNAME}.crt"
EXT="$OUT_DIR/${HOSTNAME}.ext"

if [[ ! -f "$ROOT_KEY" || ! -f "$ROOT_CRT" ]]; then
  echo "Creating local root CA in $OUT_DIR"
  openssl genrsa -out "$ROOT_KEY" 4096
  openssl req -x509 -new -nodes -key "$ROOT_KEY" -sha256 -days 3650 \
    -out "$ROOT_CRT" \
    -subj "/C=US/ST=Local/L=Homelab/O=Azul Local/OU=Homelab/CN=Azul Local Root CA"
else
  echo "Using existing local root CA in $OUT_DIR"
fi

cat > "$EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HOSTNAME}
EOF

openssl genrsa -out "$LEAF_KEY" 2048
openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" \
  -subj "/C=US/ST=Local/L=Homelab/O=Azul Local/OU=Azul/CN=${HOSTNAME}"
openssl x509 -req -in "$LEAF_CSR" -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" -CAcreateserial \
  -out "$LEAF_CRT" -days 825 -sha256 -extfile "$EXT"

kubectl -n "$APP_NAMESPACE" create secret tls "$TLS_SECRET" \
  --cert="$LEAF_CRT" --key="$LEAF_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Store the root CA private material in Kubernetes so future leaf certs can be
# regenerated without trusting files left on an operator workstation. This is
# intentionally NOT stored in git.
kubectl -n "$APP_NAMESPACE" create secret generic "$CA_SECRET" \
  --from-file=ca.crt="$ROOT_CRT" \
  --from-file=ca.key="$ROOT_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

cat > "$OUT_DIR/install-${HOSTNAME}-root-ca.ps1" <<PS1
param(
  [string]\$IngressIP = "${INGRESS_IP}",
  [string]\$CertificatePath = ".\\azul-local-root-ca.crt"
)
\$ErrorActionPreference = "Stop"
\$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not \$isAdmin) { throw "Run this script as Administrator." }
Import-Certificate -FilePath \$CertificatePath -CertStoreLocation Cert:\\LocalMachine\\Root | Out-Null
\$hostsPath = "\$env:SystemRoot\\System32\\drivers\\etc\\hosts"
\$hostsContent = Get-Content \$hostsPath -ErrorAction SilentlyContinue
\$name = "${HOSTNAME}"
if (-not (\$hostsContent -match "(?m)^\\s*\\S+\\s+\$([regex]::Escape(\$name))\\s*\$")) {
  Add-Content -Path \$hostsPath -Value "\$IngressIP`t\$name"
}
Write-Host "Installed Azul Local Root CA and hosts entry for ${HOSTNAME} -> \$IngressIP. Restart your browser."
PS1

openssl x509 -in "$LEAF_CRT" -noout -subject -issuer -dates -ext subjectAltName

echo
cat <<EOF
Created/updated:
  Kubernetes TLS secret: $APP_NAMESPACE/$TLS_SECRET
  Kubernetes CA secret:  $APP_NAMESPACE/$CA_SECRET

Windows files are in:
  $OUT_DIR

Copy this folder to Windows, open PowerShell as Administrator, then run:
  Set-ExecutionPolicy -Scope Process Bypass
  .\\install-${HOSTNAME}-root-ca.ps1 -IngressIP $INGRESS_IP
EOF
