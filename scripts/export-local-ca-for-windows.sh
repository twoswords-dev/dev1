#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-azul-infra}"
SECRET="${SECRET:-azul-infra-ca}"
OUT_DIR="${OUT_DIR:-/tmp/azul-windows-ca}"
HOSTS_DEFAULT="azul.local keycloak.local rancher.local opensearch-dashboards.local minio.local minio-api.local"

mkdir -p "$OUT_DIR"

kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "$OUT_DIR/azul-infra-ca.crt"

cat > "$OUT_DIR/install-azul-local-ca.ps1" <<'PS1'
param(
  [Parameter(Mandatory=$true)]
  [string]$IngressIP,

  [string[]]$Hostnames = @(
    "azul.local",
    "keycloak.local",
    "rancher.local",
    "opensearch-dashboards.local",
    "minio.local",
    "minio-api.local"
  ),

  [string]$CertificatePath = ".\azul-infra-ca.crt"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  throw "Run this PowerShell script as Administrator."
}

if (-not (Test-Path $CertificatePath)) {
  throw "Certificate not found: $CertificatePath"
}

Write-Host "Importing $CertificatePath into LocalMachine\Root..."
Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue

foreach ($name in $Hostnames) {
  $escaped = [regex]::Escape($name)
  $line = "$IngressIP`t$name"
  if ($hostsContent -match "(?m)^\s*\S+\s+$escaped\s*$") {
    Write-Host "Hosts entry already exists for $name"
  } else {
    Write-Host "Adding hosts entry: $line"
    Add-Content -Path $hostsPath -Value $line
  }
}

Write-Host "Done. Restart browsers, then test https://azul.local/ui/"
PS1

cat > "$OUT_DIR/README.txt" <<EOF
Copy this folder to Windows and run PowerShell as Administrator:

  Set-ExecutionPolicy -Scope Process Bypass
  .\install-azul-local-ca.ps1 -IngressIP 192.168.10.111

Change IngressIP if you want to use another ingress node IP.

Exported from Kubernetes secret: $NAMESPACE/$SECRET
EOF

chmod +x "$OUT_DIR/install-azul-local-ca.ps1" 2>/dev/null || true

echo "Wrote Windows CA installer bundle to: $OUT_DIR"
echo "Files:"
ls -l "$OUT_DIR"
