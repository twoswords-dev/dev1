# Local k3s Azul connectivity, TLS, and Windows trust

This cluster uses Kubernetes Services for pod-to-pod traffic, NGINX Ingress for browser traffic, and cert-manager for the private CA/certificates.

## 1. How pods connect to each other

Inside Kubernetes, pods normally do **not** use the public `.local` browser names. They use Kubernetes DNS names:

- Same namespace: `service-name:port`
- Cross namespace: `service-name.namespace.svc.cluster.local:port`

Examples from this deployment:

| Caller | Target | In-cluster URL |
|---|---|---|
| Azul REST API / metastore | OpenSearch | `https://azul-opensearch.azul-infra.svc.cluster.local:9200` |
| Azul REST API | Keycloak metadata | `https://keycloak.azul-infra.svc.cluster.local/realms/azul` |
| Browser | Azul | `https://azul.local/ui/` |
| Browser | Keycloak | `https://keycloak.local/realms/azul` |
| Browser | Rancher | `https://rancher.local/` |
| Browser | OpenSearch Dashboards | `https://opensearch-dashboards.local/` |

Important split:

- `security.oidc.authority_url` is the **browser/public issuer** URL used by the Web UI:

  ```yaml
  security:
    oidc:
      authority_url: https://keycloak.local/realms/azul
  ```

- `restapi.oidc.authority_url` is the **server-side/in-cluster** URL used by Azul REST API token validation:

  ```yaml
  restapi:
    oidc:
      authority_url: https://keycloak.azul-infra.svc.cluster.local/realms/azul
  ```

This is needed because pods do not reliably resolve `keycloak.local`, but they do resolve Kubernetes service DNS.

## 2. Where TLS/cert-manager is configured

### Infra CA

`infra/templates/cert-manager.yaml` creates:

1. A self-signed issuer.
2. A CA certificate secret.
3. A normal CA issuer named `azul-infra-ca`.

The k3s values are in `infra/values-k3s-infra.yaml`:

```yaml
certManager:
  selfSignedIssuerName: azul-infra-selfsigned
  caCertificateName: azul-infra-ca
  caSecretName: azul-infra-ca
  issuerName: azul-infra-ca
```

That means cert-manager creates a private local CA stored as:

```text
namespace: azul-infra
secret: azul-infra-ca
key: ca.crt
```

### Keycloak TLS

Keycloak has two TLS layers:

1. **Internal pod/service TLS**: configured by `keycloak.tls`.
2. **Ingress/browser TLS**: configured by `keycloak.ingress`.

From `infra/values-k3s-infra.yaml`:

```yaml
keycloak:
  hostnameArg: https://keycloak.local
  extraArgs:
    - --hostname-backchannel-dynamic=true
  tls:
    enabled: true
    secretName: keycloak-internal-tls
    issuerRef:
      name: azul-infra-ca
      kind: Issuer
  ingress:
    hostname: keycloak.local
    secretName: keycloak-tls
    annotations:
      cert-manager.io/issuer: azul-infra-ca
```

### OpenSearch TLS and OIDC

OpenSearch node/admin certs are created in `infra/templates/opensearch.yaml` using the issuer reference in `infra/values-k3s-infra.yaml`:

```yaml
opensearch:
  issuerRef:
    name: azul-infra-ca
    kind: Issuer
```

OpenSearch and OpenSearch Dashboards use Keycloak OIDC with the in-cluster Keycloak service URL:

```yaml
opensearch_security.openid.connect_url: https://keycloak.azul-infra.svc.cluster.local/realms/azul/.well-known/openid-configuration
```

### Azul app CA bundle

Azul application pods mount a ConfigMap specified by `CACertificateConfigMap`:

```yaml
CACertificateConfigMap: azul-ca-bundle
```

The chart renders `azul/templates/core/ca-bundle-configmap.yaml` from the file:

```text
azul/ca-certificates
```

Pods mount it as:

```text
/cafile/ca.crt
```

and set:

```text
SSL_CERT_FILE=/cafile/ca.crt
REQUESTS_CA_BUNDLE=/cafile/ca.crt
```

So if you change the local CA, append the new CA certificate to `azul/ca-certificates` and resync Azul.

## 3. Windows browser HTTPS trust

For a Windows browser to trust `https://azul.local`, `https://keycloak.local`, and friends, Windows needs two things:

1. The names must resolve to your ingress IP.
2. The certificate chain must be trusted by Windows.

### DNS / hosts entries

Yes: you need DNS or hosts entries for every browser-facing hostname you use.

At minimum:

```text
azul.local
keycloak.local
rancher.local
opensearch-dashboards.local
```

Point them at one of your NGINX ingress node IPs, for example:

```text
192.168.10.111 azul.local keycloak.local rancher.local opensearch-dashboards.local
```

If you use MinIO from Windows, also add:

```text
minio.local
minio-api.local
```

### Certificate SANs and ingress hosts

Each HTTPS hostname must appear in the certificate SANs for the TLS secret used by that Ingress.

Current ingresses are separate:

- Azul: `azul.local` using `azul-external-web-tls` in namespace `azul-app`
- Keycloak: `keycloak.local` using `keycloak-tls` in namespace `azul-infra`
- Rancher: `rancher.local` using its Rancher TLS secret
- OpenSearch Dashboards: `opensearch-dashboards.local` using `dashboard-ingress-tls` in namespace `azul-infra`

You do **not** need to put both `azul.local` and `keycloak.local` on both ingresses. You need:

- `azul.local` on the Azul ingress and its certificate.
- `keycloak.local` on the Keycloak ingress and its certificate.

A single wildcard or multi-SAN certificate can cover many hosts, but each Ingress still needs the correct `rules.host` and `tls.hosts` entries for the host it serves.

## 4. Installing local CAs on Windows

### Azul external Web TLS, not cert-manager

Azul's browser ingress can use a manually-created TLS secret instead of cert-manager. The current secret is:

```text
namespace: azul-app
secret: azul-external-web-tls
```

and the values point the web ingress at it:

```yaml
web:
  ingress:
    secretName: azul-external-web-tls
```

To recreate/update this manually-managed CA and `azul.local` leaf certificate, run from a machine with `kubectl` access:

```bash
scripts/create-azul-external-web-tls.sh
```

It creates:

```text
/tmp/azul-external-web-tls/
  azul-local-root-ca.crt        # import this into Windows Trusted Root
  azul-local-root-ca.key        # private CA key, do not commit
  azul.local.crt                # leaf cert served by ingress
  azul.local.key                # leaf private key stored in azul-external-web-tls
  install-azul.local-root-ca.ps1
```

It also stores the CA material in Kubernetes, not git:

```text
azul-app/azul-external-root-ca
```

Copy `/tmp/azul-external-web-tls` to Windows, then run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-azul.local-root-ca.ps1 -IngressIP 192.168.10.111
```

This imports only the root CA into Windows and adds a hosts-file entry for `azul.local`.

### Infra CA for Keycloak/Rancher/OpenSearch Dashboards

Keycloak and OpenSearch Dashboards are still using cert-manager/infra CA certificates. To export that CA for Windows, use:

```bash
scripts/export-local-ca-for-windows.sh
```

It writes a folder like:

```text
/tmp/azul-windows-ca/
  azul-infra-ca.crt
  install-azul-local-ca.ps1
```

Copy that folder to Windows, then run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-azul-local-ca.ps1 -IngressIP 192.168.10.111
```

After that, restart your browser and open:

```text
https://azul.local/ui/
```

## 5. Do you need an intermediate CA?

Not strictly. For a homelab/local k3s cluster, trusting the cert-manager-generated `azul-infra-ca` root on Windows is enough.

A more formal setup is:

```text
Offline root CA -> online Kubernetes intermediate CA -> leaf ingress/service certs
```

Benefits:

- You can keep the root private/offline.
- You can rotate/revoke the intermediate without replacing the root trust on Windows.

Downside:

- More moving pieces.
- You must replace the current cert-manager CA issuer secret and rotate all certs.

For now, use the existing `azul-infra-ca` unless you specifically want a production-style PKI hierarchy.
