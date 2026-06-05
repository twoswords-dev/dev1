# Company multi-SAN certificate for Azul browser-facing ingresses

This document describes how to use a company-provided certificate that contains
multiple DNS Subject Alternative Names (SANs), for example:

```text
DNS:azul.local
DNS:keycloak.local
DNS:opensearch-dashboards.local
DNS:minio.local
DNS:minio-api.local
```

This is for **browser-facing ingress TLS only**. It does not replace internal
pod/service TLS unless explicitly called out.

## What a `.cer` file is, and what else you need

A company `.cer` file usually contains only the **public certificate**. That is
not enough to create a Kubernetes TLS secret.

For Kubernetes ingress TLS, you always need the private key that matches the
certificate. The server proves ownership of the certificate during the TLS
handshake by using that private key.

Valid inputs are either:

```text
company.cer + matching company.key
```

or:

```text
you generate company.key + company.csr
company signs company.csr and returns company.cer
you use returned company.cer with your original company.key
```

A `.cer` by itself is not enough unless you already have the private key that was
used to generate the CSR for that certificate.

To use it with Kubernetes ingresses you need:

```text
company.cer              # public leaf/server certificate with the needed SANs
company.key              # matching private key
company-intermediate.cer # intermediate/issuing CA certificate(s)
company-root.cer         # root CA, usually for client trust, not usually served
```

You may receive the intermediate and root separately, or as a bundle. Ask company
PKI for the intermediate/issuing CA chain if you do not already have it.

## Verify the certificate SANs

If the `.cer` is DER encoded, convert it to PEM:

```bash
openssl x509 -inform DER -in company.cer -out company.crt
```

If it is already PEM encoded:

```bash
cp company.cer company.crt
```

Inspect it:

```bash
openssl x509 -in company.crt -noout -subject -issuer -dates -ext subjectAltName
```

Confirm every hostname you intend to serve appears in `subjectAltName`.

Minimum hostnames for the current local deployment are normally:

```text
azul.local
keycloak.local
opensearch-dashboards.local
minio.local
minio-api.local
```

Optional hostnames, depending on what you expose, include:

```text
minio-backup.local
minio-backup-api.local
opensearch.local or opensearch.azul.internal
rancher.local
argocd.local
longhorn.local
```

The SAN must match the exact hostname used by the browser. A certificate for
`azul.company.com` does not validate `azul.local` unless both names are present
as SANs.

## Verify the private key matches

You must have the private key that matches the certificate.

For RSA keys:

```bash
openssl x509 -in company.crt -noout -modulus | openssl md5
openssl rsa -in company.key -noout -modulus | openssl md5
```

The hashes must match.

For non-RSA keys, compare public keys instead:

```bash
openssl x509 -in company.crt -pubkey -noout | openssl pkey -pubin -outform pem | sha256sum
openssl pkey -in company.key -pubout -outform pem | sha256sum
```

The hashes must match.

## Build the served full chain

The ingress TLS secret should contain the leaf certificate plus intermediate(s):

```bash
cat company.crt company-intermediate.cer > fullchain.crt
```

If there are multiple intermediates, include them in chain order:

```bash
cat company.crt issuing-intermediate.crt higher-intermediate.crt > fullchain.crt
```

Do not normally include the root CA in `fullchain.crt` unless company PKI
explicitly requires it.

## Kubernetes secrets used by current charts

Current browser-facing ingress TLS secrets are:

| Service | Namespace | TLS secret | Notes |
| --- | --- | --- | --- |
| Azul UI/API | `azul-app` | `azul-external-web-tls` | Managed by `scripts/create-azul-external-web-tls.sh` or `kubectl create secret tls`. |
| Keycloak ingress | `azul-infra` | `keycloak-tls` | Browser-facing only. Do not replace `keycloak-internal-tls` unless doing internal TLS replacement. |
| OpenSearch Dashboards | `azul-infra` | `dashboard-ingress-tls` | Browser-facing Dashboards ingress. |
| MinIO primary | `azul-infra` | `minio-tls` | Covers `minio.local` and `minio-api.local`. |
| MinIO backup | `azul-infra` | `minio-backup-tls` | Only relevant if backup MinIO ingress is enabled. |
| OpenSearch direct ingress | `azul-infra` | `opensearch-tls` | Only relevant if direct OpenSearch ingress is enabled. It is disabled in the current k3s values. |

## Apply the same multi-SAN cert to all browser-facing ingresses

After building `fullchain.crt` and confirming `company.key` matches it, create or
update the relevant Kubernetes TLS secrets.

```bash
# Azul external browser TLS
kubectl -n azul-app create secret tls azul-external-web-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -

# Keycloak browser ingress TLS
kubectl -n azul-infra create secret tls keycloak-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -

# OpenSearch Dashboards browser ingress TLS
kubectl -n azul-infra create secret tls dashboard-ingress-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -

# MinIO browser/API ingress TLS
kubectl -n azul-infra create secret tls minio-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

If backup MinIO ingress is enabled:

```bash
kubectl -n azul-infra create secret tls minio-backup-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

If direct OpenSearch ingress is enabled and the cert contains that hostname:

```bash
kubectl -n azul-infra create secret tls opensearch-tls \
  --cert=fullchain.crt \
  --key=company.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Avoid cert-manager overwriting manual company secrets

Many current ingress values include:

```yaml
cert-manager.io/issuer: azul-infra-ca
```

That annotation tells cert-manager ingress-shim to manage the referenced TLS
secret using the local k3s CA. If you manually provide company TLS secrets, you
should remove or override that annotation for those browser-facing ingresses, or
replace it with a company-backed cert-manager issuer if one exists.

Manual-secret mode means values should not include this annotation on the
company-managed ingress secrets:

```yaml
cert-manager.io/issuer: azul-infra-ca
```

So yes: if you manually provide company TLS secrets, remove the local
`azul-infra-ca` cert-manager annotations from the affected browser-facing
Ingress values, or cert-manager may overwrite/regenerate those secrets.

Company-cert-manager mode means you would instead configure something like:

```yaml
cert-manager.io/cluster-issuer: company-pki
```

or the issuer name/type provided by your PKI/cert-manager integration.

## Using the existing Azul helper script

For Azul alone, the existing script can consume a company certificate/key:

```bash
cd /tmp/azul-app

AZUL_HOSTNAME=azul.local \
TLS_CERT_FILE=/path/to/fullchain.crt \
TLS_KEY_FILE=/path/to/company.key \
scripts/create-azul-external-web-tls.sh
```

That only updates:

```text
azul-app/azul-external-web-tls
```

For Keycloak, Dashboards, and MinIO, use `kubectl create secret tls` as shown
above, or add a separate helper script later.

## Windows/client trust

If the Windows PC is domain-managed, it may already trust the company root and
intermediate CAs.

If not, import the company trust chain using company-approved procedures:

```text
company-root.cer         -> LocalMachine\Root
company-intermediate.cer -> LocalMachine\CA
```

Do not import the private key into Windows trust stores.

## Verify each ingress serves the company certificate

Use SNI for each hostname:

```bash
for host in azul.local keycloak.local opensearch-dashboards.local minio.local minio-api.local; do
  echo "=== $host ==="
  openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
done
```

Expected:

- Subject/issuer reflect company PKI.
- SANs include each hostname.
- Dates are valid.
- Browser no longer warns about local/self-signed CA, assuming Windows trusts the
  company root/intermediate.

## What not to change for browser-facing TLS only

Do not replace these unless intentionally doing internal service TLS replacement:

```text
azul-infra/keycloak-internal-tls
azul-infra/azul-opensearch-certs
azul-infra/azul-opensearch-ca-cert
azul-infra/azul-opensearch-admin-certs
azul-app/azul-ca-bundle
```

Those are used for pod-to-pod/service trust and OpenSearch security. Changing
them requires updating CA bundles, OpenSearch security config, and restart order.

## If company PKI must replace internal TLS too

That is a separate project. It would require planning for:

```text
Keycloak internal service certificate with Kubernetes service DNS SANs
OpenSearch HTTP and transport certificates with operator-required SANs/usages
OpenSearch admin certificate/securityadmin requirements
Azul mounted CA bundle at /cafile/ca.crt
OpenSearch/Dashboards CA bundles
cert-manager issuers or manually managed secrets
pod restart order and Argo ignore rules
```

Do not mix internal TLS replacement into the initial browser-facing certificate
test. First prove the cluster works, then prove browser-facing company TLS, then
plan internal TLS separately if required.
