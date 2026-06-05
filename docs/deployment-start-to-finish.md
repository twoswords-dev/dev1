# Azul k3s deployment: start to finish

This is the tested local/homelab deployment flow for this repo.

See also `docs/ad-hoc-fixes-ledger.md` for the live fixes discovered during the
initial bring-up and whether each one is now baked into the repo or remains an
intentional runtime/scripted step.

## Applications

| Argo app | Chart path | Namespace | Values file |
|---|---|---|---|
| `azul-infra` | `infra/` | `azul-infra` | `infra/values.yaml` |
| `azul` | `azul/` | `azul-app` | `azul/values.yaml` |

Local endpoints currently used by the values/scripts:

```text
azul.local
keycloak.local
opensearch-dashboards.local
minio.local
minio-api.local
```

## 1. Prerequisites

On the admin workstation: `kubectl`, `helm`, `openssl`, `jq`, `curl`.

In the cluster:

- Argo CD installed in namespace `argocd`.
- Ingress controller using `ingressClassName: nginx`.
- Storage class `longhorn`.
- cert-manager installed.
- DNS or hosts-file entries for the local endpoint names.
- Images available to the cluster.

If you previously used the stop/start helper, make sure Azul is powered back on before validating:

```bash
cd /data/azul-app
infra/scripts/azul-power.sh on || true
infra/scripts/azul-power.sh status
```

## 2. Create namespaces first

The committed secrets include namespace fields, but the namespaces must exist before applying them:

```bash
cd /data/azul-app
kubectl create namespace azul-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace azul-app --dry-run=client -o yaml | kubectl apply -f -
```

## 3. Apply required non-certificate secrets

Apply the committed secret manifests before Argo syncs:

```bash
kubectl apply -f infra/creds.yaml
kubectl apply -f azul/creds.yaml
```

The secret manifests include explicit namespaces (`azul-infra` and `azul-app`).

`creds.yaml` intentionally does **not** contain hard-coded TLS certificates or
runtime CA bundles. Infra TLS is issued by cert-manager from `azul-infra-ca`.
OpenSearch Dashboards is declared for OIDC in `infra/values*.yaml` and disables
TLS verification to OpenSearch during bootstrap to avoid a security-bootstrap
catch-22. The Keycloak and OpenSearch configuration scripts create/update the
`opensearch-dashboards-oidc` secret with the real client secret and apply the
OpenSearch OIDC security config. The Dashboards Ingress sets larger nginx proxy
header buffers because OIDC login can return large session cookies; without
those annotations the callback fails with `502 upstream sent too big header`.

These contain live base64-encoded non-certificate values for this environment. To rotate instead, set explicit values and run:

```bash
export S3_ACCESS_KEY='...'
export S3_SECRET_KEY='...'
export KEYCLOAK_ADMIN_PASSWORD='...'
export KEYCLOAK_DB_PASSWORD='...'
export OPENSEARCH_ADMIN_PASSWORD='...'
export OPENSEARCH_DASHBOARD_PASSWORD='...'
export REDIS_PASSWORD='...'
export OPENSEARCH_AZUL_WRITER_PASSWORD='...'
export JWT_SIGNING_SECRET='...'
infra/scripts/create-k3s-infra-secrets.sh
azul/scripts/create-k3s-app-secrets.sh
```

## 4. Deploy infra with Argo CD

Apply infra first and wait for cert-manager-issued infra certificates,
OpenSearch, Keycloak, Kafka, Postgres, and MinIO to come up:

```bash
kubectl apply -f argocd/azul-infra-application.yaml
kubectl -n argocd get applications.argoproj.io azul-infra -w
kubectl -n azul-infra get pods
```

OpenSearch may log `OpenSearch Security not initialized` during first boot; that
is expected until the operator security-config job completes. The startup and readiness probes initially check only that port 9200 is
listening. This intentionally publishes service endpoints before the security
index exists, so the operator securityadmin job can initialize OpenSearch.

## 5. Create Azul external web TLS secret

The Azul web ingress references `azul-app/azul-external-web-tls`. For the
initial homelab/hosts-file bring-up, sign it with the cert-manager-created infra
CA after `azul-infra` exists:

```bash
AZUL_HOSTNAME=azul.local \
INGRESS_IP=192.168.10.111 \
scripts/create-azul-external-web-tls.sh
```

Later, replace it with a company/provided certificate:

```bash
AZUL_HOSTNAME=azul.local \
TLS_CERT_FILE=/path/to/fullchain.crt \
TLS_KEY_FILE=/path/to/tls.key \
scripts/create-azul-external-web-tls.sh
```

## 6. Deploy Azul with Argo CD

```bash
kubectl apply -f argocd/azul-application.yaml
kubectl -n argocd get applications.argoproj.io azul -w
kubectl -n azul-app get pods
```

Use `applications.argoproj.io`; plain `kubectl get app` can resolve to Rancher `apps.catalog.cattle.io` on this cluster.

## 7. Add the infra CA to the Azul app CA bundle

After the Azul app has created `azul-app/azul-ca-bundle`, append the runtime
cert-manager CA from `azul-infra/azul-infra-ca` so Azul pods trust OpenSearch and
Keycloak:

```bash
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart deploy,sts
```

The Argo CD app is configured to ignore live differences for this ConfigMap key,
but after a fresh sync or self-heal always verify the runtime CA is still present
and rerun the script if Azul logs show TLS verification failures.

## 8. Configure Keycloak for Azul

Run after Keycloak is ready. This also creates/updates the Kubernetes Secret `azul-infra/opensearch-dashboards-oidc`, which OpenSearch Dashboards needs for its OIDC client secret.

```bash
KEYCLOAK_URL=https://keycloak.local \
AZUL_URL=https://azul.local \
OPENSEARCH_DASHBOARDS_URL=https://opensearch-dashboards.local \
infra/scripts/configure-keycloak-azul.sh
```

## 9. Configure OpenSearch security/OIDC

Run after OpenSearch, Keycloak, and Azul restapi are ready:

```bash
infra/scripts/configure-opensearch-security-azul.sh
```

The OpenSearch OIDC settings are kept in `infra/values*.yaml`; the script fills
in runtime state that cannot be committed safely, including Keycloak client
secrets, OpenSearch role mappings/users, and app-side secrets. It switches Azul
from the bootstrap `admin` OpenSearch account to the least-privilege
`azul_writer` account. The committed app secret defaults now match this writer
password so Argo does not revert Azul back to an invalid bootstrap password.
After it runs, refresh the Azul CA bundle and restart the pods that talk to
OpenSearch/Keycloak:

```bash
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart deploy/ms-ingest-binary deploy/ms-ingest-status deploy/ms-ageoff sts/restapi
```

## 10. Validate

```bash
kubectl -n azul-infra get pods,svc,ingress,secrets
kubectl -n azul-app get pods,svc,ingress,secrets
kubectl -n azul-app get secret azul-external-web-tls
kubectl -n argocd get applications.argoproj.io azul-infra azul
```

Check certificates and runtime CA propagation:

```bash
openssl s_client -connect azul.local:443 -servername azul.local </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
openssl s_client -connect keycloak.local:443 -servername keycloak.local </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
kubectl -n azul-app exec restapi-0 -- sh -c 'grep -c "BEGIN CERTIFICATE" /cafile/ca.crt'
kubectl -n azul-app exec restapi-0 -- python3 - <<'PY'
from pathlib import Path
print('Azul Infra CA in mounted bundle:', 'CN=Azul Infra CA' in Path('/cafile/ca.crt').read_text())
PY
```

Browse:

```text
https://azul.local/ui/
https://keycloak.local/
https://opensearch-dashboards.local/
https://minio.local/
```

## 11. Rebuild order summary

```bash
cd /data/azul-app
kubectl create namespace azul-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace azul-app --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f infra/creds.yaml
kubectl apply -f azul/creds.yaml
kubectl apply -f argocd/azul-infra-application.yaml
kubectl -n argocd get applications.argoproj.io azul-infra -w
AZUL_HOSTNAME=azul.local INGRESS_IP=192.168.10.111 scripts/create-azul-external-web-tls.sh
kubectl apply -f argocd/azul-application.yaml
kubectl -n argocd get applications.argoproj.io azul -w
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart deploy,sts
KEYCLOAK_URL=https://keycloak.local AZUL_URL=https://azul.local OPENSEARCH_DASHBOARDS_URL=https://opensearch-dashboards.local infra/scripts/configure-keycloak-azul.sh
infra/scripts/configure-opensearch-security-azul.sh
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart deploy/ms-ingest-binary deploy/ms-ingest-status deploy/ms-ageoff sts/restapi
```

## 12. Troubleshooting notes

### Azul login succeeds but API access fails with certificate errors

If `restapi` logs contain:

```text
httpx.ConnectError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate
```

then the current cert-manager-generated `azul-infra-ca` is missing from the
mounted Azul CA bundle. Re-sync the runtime CA and restart the pods that mount
it:

```bash
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart sts/restapi deploy/ms-ingest-binary deploy/ms-ingest-status deploy/ms-ageoff
kubectl -n azul-app exec restapi-0 -- sh -c 'grep -c "BEGIN CERTIFICATE" /cafile/ca.crt'
```

A successful in-pod smoke test is:

```bash
kubectl -n azul-app exec restapi-0 -- python3 - <<'PY'
import httpx
for url in [
    'https://keycloak.azul-infra.svc.cluster.local/realms/azul/.well-known/openid-configuration',
    'https://azul-opensearch.azul-infra.svc.cluster.local:9200',
]:
    r = httpx.get(url, timeout=10)
    print(url, r.status_code)
PY
```

Expected result: Keycloak returns `200`; OpenSearch returns `401` without auth,
which confirms TLS trust is working.

### OpenSearch Dashboards returns 502 after Keycloak login

Check ingress-nginx logs for `upstream sent too big header`. The chart should
include these annotations on the Dashboards Ingress:

```yaml
nginx.ingress.kubernetes.io/proxy-buffer-size: 16k
nginx.ingress.kubernetes.io/proxy-buffers-number: '8'
```
