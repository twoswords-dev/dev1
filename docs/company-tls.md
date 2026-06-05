# Company TLS for Azul external browser access

This document covers **Azul external browser TLS only**: the certificate served
by the `azul.local` ingress to users' browsers.

For this use case, you should **not manually edit ConfigMaps** and usually
should **not hand-edit Kubernetes Secrets**. Use the existing helper script with
your company-provided certificate and key.

## Scope

This document changes only the browser-facing Azul TLS secret:

```text
azul-app/azul-external-web-tls
```

It does **not** replace internal cluster TLS for Keycloak, OpenSearch, MinIO,
Postgres, or cert-manager-generated service certificates.

If you later want company PKI to replace internal service TLS as well, that is a
separate task and will require updating CA bundles and more secrets.

## What you need from company PKI

For browser TLS you need either:

1. A company-issued leaf certificate and matching private key, or
2. A CSR workflow where you generate a private key/CSR and company PKI signs it.

The certificate must include the hostname users browse to, for example:

```text
DNS:azul.local
```

If the company wants a different DNS name, update the ingress hostname and
related Azul/Keycloak URLs before issuing the certificate.

## Case 1: company provides leaf cert and private key

You need two files on the Linux/k3s admin machine:

```text
fullchain.crt  # Azul leaf cert followed by intermediate certificate(s)
tls.key        # matching private key
```

The `fullchain.crt` should usually be ordered like this:

```text
-----BEGIN CERTIFICATE-----
Azul leaf certificate for azul.local
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
Company intermediate CA
-----END CERTIFICATE-----
```

Do not normally include the root CA in the served full chain unless your PKI
team explicitly requires it.

Apply the cert/key using the repo script:

```bash
cd /tmp/azul-app

AZUL_HOSTNAME=azul.local \
TLS_CERT_FILE=/path/to/fullchain.crt \
TLS_KEY_FILE=/path/to/tls.key \
scripts/create-azul-external-web-tls.sh
```

This creates or updates:

```text
azul-app/azul-external-web-tls
```

No ConfigMap edit is required.

## Case 2: company wants a CSR

Generate a private key and CSR locally:

```bash
openssl genrsa -out azul.local.key 2048

openssl req -new \
  -key azul.local.key \
  -out azul.local.csr \
  -subj "/CN=azul.local" \
  -addext "subjectAltName=DNS:azul.local"
```

Send this file to company PKI:

```text
azul.local.csr
```

Keep this file private and secure:

```text
azul.local.key
```

When company PKI returns the signed certificate and intermediate CA, build the
full chain:

```bash
cat azul.local.crt company-intermediate.crt > fullchain.crt
```

Then apply it:

```bash
cd /tmp/azul-app

AZUL_HOSTNAME=azul.local \
TLS_CERT_FILE=$PWD/fullchain.crt \
TLS_KEY_FILE=$PWD/azul.local.key \
scripts/create-azul-external-web-tls.sh
```

## Windows trust

If your Windows PC is domain-managed, it may already trust the company root and
intermediate CAs.

If not, import the company root CA into:

```text
LocalMachine\Root
```

and import the company intermediate CA into:

```text
LocalMachine\CA
```

Use your company-approved process for this. Do not import private keys into the
Windows trust stores.

## Verify the live ingress certificate

After applying the company certificate, verify what ingress serves:

```bash
openssl s_client -connect azul.local:443 -servername azul.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Expected:

- `subject` identifies `azul.local` or the approved company DNS name.
- `issuer` is the company issuing/intermediate CA.
- `subjectAltName` includes `DNS:azul.local` or the approved hostname.
- The dates are valid.

Also test from a browser:

```text
https://azul.local/ui/
```

## What not to do

Do not commit company certificates, private keys, CSRs, or generated secrets.

Do not manually edit these for external browser TLS:

```text
ConfigMaps
azul-app/azul-ca-bundle
azul-infra/azul-opensearch-certs
```

Those CA bundles are for internal trust between Azul, Keycloak, and OpenSearch.
They are separate from the browser-facing Azul ingress certificate.

Do not manually patch the TLS secret unless the script is unavailable. Prefer:

```bash
scripts/create-azul-external-web-tls.sh
```

## If replacing internal cluster TLS later

Replacing internal service TLS with company PKI is a separate project. It would
likely require updating or replacing certificates and CA trust for:

```text
Keycloak ingress/service TLS
OpenSearch transport/http TLS
OpenSearch Dashboards OIDC trust
Azul app CA bundle mounted at /cafile/ca.crt
azul-infra/azul-opensearch-certs
cert-manager issuers/secrets
possibly Argo CD ignore rules and restart order
```

That should be planned separately from Azul external browser TLS.
