# Homelab/local TLS flow

This document explains the local TLS flow used for the k3s homelab deployment.
It is different from using company PKI.

## Summary

The working local flow is:

```text
cert-manager local CA -> signs local service/ingress certificates -> Kubernetes ingresses serve those certificates -> Windows trusts the local CA
```

For the current deployment, the important local CA is:

```text
azul-infra/azul-infra-ca
```

That CA is generated inside the cluster by cert-manager resources from the
`azul-infra` chart.

## Step-by-step flow

### 1. Deploy `azul-infra`

The `azul-infra` Argo app deploys cert-manager resources and creates the local
issuer/CA material used by the homelab deployment.

The resulting CA secret is:

```text
namespace: azul-infra
secret:    azul-infra-ca
```

This secret contains the local CA certificate and private key used to issue local
certificates for services such as Keycloak, OpenSearch Dashboards, MinIO, and
Azul external browser TLS.

## 2. Generate Azul external browser TLS

The helper script uses the local CA to create a browser-facing certificate for
Azul:

```bash
cd /tmp/azul-app

AZUL_HOSTNAME=azul.local \
INGRESS_IP=192.168.10.111 \
scripts/create-azul-external-web-tls.sh
```

The script reads the signing CA from:

```text
azul-infra/azul-infra-ca
```

Then it creates a leaf/server certificate for:

```text
DNS:azul.local
IP:192.168.10.111
```

The certificate is issued by:

```text
CN=Azul Infra CA
```

The script creates or updates this Kubernetes TLS secret:

```text
namespace: azul-app
secret:    azul-external-web-tls
```

The Azul ingress references this secret, so browsers receive the `azul.local`
certificate when visiting:

```text
https://azul.local/ui/
```

## 3. Export the local CA for Windows

Windows does not automatically trust the cluster-generated local CA. Export the
CA and installer bundle:

```bash
cd /tmp/azul-app
scripts/export-local-ca-for-windows.sh
```

This writes a Windows bundle to:

```text
/tmp/azul-windows-ca
```

Copy that folder to Windows.

## 4. Install the CA and hosts entries on Windows

On Windows, open PowerShell as Administrator in the copied folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-azul-local-ca.ps1 -IngressIP 192.168.10.111
```

This does two things:

1. Imports the local `azul-infra-ca` certificate into the Windows trusted root
   certificate store.
2. Adds hosts-file entries pointing local service names at the k3s ingress IP.

Typical browser hostnames are:

```text
azul.local
keycloak.local
opensearch-dashboards.local
minio.local
minio-api.local
rancher.local
```

After this, restart the browser.

## 5. Test from Windows

Browse to:

```text
https://azul.local/ui/
https://keycloak.local/
https://opensearch-dashboards.local/
https://minio.local/
```

The browser should trust the certificates because Windows now trusts the local
homelab CA.

## Verify from Linux

To inspect the live Azul ingress certificate:

```bash
openssl s_client -connect azul.local:443 -servername azul.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Expected output includes:

```text
subject=... CN = azul.local
issuer=CN = Azul Infra CA
X509v3 Subject Alternative Name:
    DNS:azul.local, IP Address:192.168.10.111
```

## Relationship to company TLS

This homelab flow proves the cluster and browser TLS wiring work.

Company PKI uses the same Kubernetes ingress shape, but swaps the local CA-signed
certificate for a company-issued certificate and matching private key.

Homelab/local flow:

```text
azul-infra-ca signs azul.local -> Windows trusts azul-infra-ca
```

Company flow:

```text
company CA signs azul.local or company DNS name -> Windows already trusts company CA
```

For company TLS details, see:

```text
docs/company-tls.md
docs/company-multi-san-ingress-tls.md
```

## Important notes

Do not commit generated local CA private keys or generated certificates.

The generated local material is runtime/environment-specific. It belongs in
Kubernetes secrets or temporary export folders, not in Git.

Use:

```bash
scripts/create-azul-external-web-tls.sh
scripts/export-local-ca-for-windows.sh
```

rather than manually editing Kubernetes secrets or ConfigMaps.
