# Azul k3s deployment: start to finish

This is the tested local/homelab deployment flow for this repo.

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

## 3. Apply required secrets

For this internal rebuild, apply the committed secret manifests before Argo syncs:

```bash
kubectl apply -f infra/creds.yaml
kubectl apply -f azul/creds.yaml
```

These contain live base64-encoded values for this environment. To rotate instead, set explicit values and run:

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

## 4. Create Azul external web TLS secret

The Azul web ingress references `azul-app/azul-external-web-tls`.

Company/provided cert:

```bash
AZUL_HOSTNAME=azul.local \
TLS_CERT_FILE=/path/to/fullchain.crt \
TLS_KEY_FILE=/path/to/tls.key \
scripts/create-azul-external-web-tls.sh
```

Local CA fallback:

```bash
AZUL_HOSTNAME=azul.local \
INGRESS_IP=192.168.10.111 \
scripts/create-azul-external-web-tls.sh
```

## 5. Deploy with Argo CD

Apply infra first, then wait at least for Keycloak to be ready. Do not wait for full infra health before Keycloak setup: OpenSearch Dashboards may remain pending until the `opensearch-dashboards-oidc` secret is created by the Keycloak setup script.

```bash
kubectl apply -f argocd/azul-infra-application.yaml
kubectl -n azul-infra wait --for=condition=Ready pod -l app=keycloak --timeout=300s
kubectl -n azul-infra get pods
```

Then run the Keycloak setup in step 6, then apply Azul:

```bash
kubectl apply -f argocd/azul-application.yaml
kubectl -n argocd get applications.argoproj.io azul -w
kubectl -n azul-app get pods
```

Use `applications.argoproj.io`; plain `kubectl get app` can resolve to Rancher `apps.catalog.cattle.io` on this cluster.

## 6. Configure Keycloak for Azul

Run after Keycloak is ready. This also creates/updates the Kubernetes Secret `azul-infra/opensearch-dashboards-oidc`, which OpenSearch Dashboards needs for its OIDC client secret.

```bash
KEYCLOAK_URL=https://keycloak.local \
AZUL_URL=https://azul.local \
OPENSEARCH_DASHBOARDS_URL=https://opensearch-dashboards.local \
infra/scripts/configure-keycloak-azul.sh
```

## 7. Configure OpenSearch security/OIDC

Run after OpenSearch and Keycloak are ready:

```bash
infra/scripts/configure-opensearch-security-azul.sh
```

## 8. Validate

```bash
kubectl -n azul-infra get pods,svc,ingress,secrets
kubectl -n azul-app get pods,svc,ingress,secrets
kubectl -n azul-app get secret azul-external-web-tls
kubectl -n argocd get applications.argoproj.io azul-infra azul
```

Check certificates:

```bash
openssl s_client -connect azul.local:443 -servername azul.local </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
openssl s_client -connect keycloak.local:443 -servername keycloak.local </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Browse:

```text
https://azul.local/ui/
https://keycloak.local/
https://opensearch-dashboards.local/
https://minio.local/
```

## 9. Rebuild order summary

```bash
cd /data/azul-app
kubectl create namespace azul-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace azul-app --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f infra/creds.yaml
kubectl apply -f azul/creds.yaml
AZUL_HOSTNAME=azul.local INGRESS_IP=192.168.10.111 scripts/create-azul-external-web-tls.sh
kubectl apply -f argocd/azul-infra-application.yaml
kubectl -n azul-infra wait --for=condition=Ready pod -l app=keycloak --timeout=300s
KEYCLOAK_URL=https://keycloak.local AZUL_URL=https://azul.local OPENSEARCH_DASHBOARDS_URL=https://opensearch-dashboards.local infra/scripts/configure-keycloak-azul.sh
kubectl apply -f argocd/azul-application.yaml
kubectl -n argocd get applications.argoproj.io azul -w
infra/scripts/configure-opensearch-security-azul.sh
```
