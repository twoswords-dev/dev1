# Azul k3s ad-hoc fixes ledger

This file records the live/ad-hoc fixes that were needed while bringing Azul up
on k3s, and whether they are now baked into the repo or remain an intentional
runtime step for a clean redeploy.

Use this as a pre-flight checklist before the next complete redeployment.

## Status legend

- **Baked**: represented in Helm values, manifests, or scripts in this repo.
- **Runtime step**: intentionally not committed because it depends on
  cert-manager-generated material or live secrets. It is documented and scripted.
- **Diagnostic only**: used for troubleshooting; do not carry into a clean deploy.

## Fixes and follow-up status

| Area | What was done live | Current repo status | Clean redeploy action |
| --- | --- | --- | --- |
| Runtime infra CA for Azul pods | Ran `scripts/update-azul-app-ca-bundle.sh` after `azul-ca-bundle` existed; restarted `restapi`, `ms-ingest-binary`, `ms-ingest-status`, and `ms-ageoff` to remount `/cafile/ca.crt`. | **Runtime step**. Script exists and `argocd/azul-application.yaml` ignores the runtime CA bundle key. Docs include the SSL error and verification commands. | Always run after Azul app sync and again after OpenSearch/Keycloak security config if TLS errors appear. Restart the pods that mount `/cafile/ca.crt`. |
| Runtime infra CA for OpenSearch/Dashboards OIDC | Appended `azul-infra-ca` into `azul-infra/azul-opensearch-certs`, then restarted OpenSearch/Dashboards so Keycloak TLS could be validated. | **Runtime step** in `infra/scripts/configure-opensearch-security-azul.sh`. `argocd/azul-infra-application.yaml` ignores the runtime `ca-certificates` key. | Run `infra/scripts/configure-opensearch-security-azul.sh` after Keycloak/OpenSearch/restapi are ready. Restart OpenSearch if the mounted CA bundle changed. |
| OpenSearch Dashboards OIDC DNS | Changed backend OIDC metadata URL from public `keycloak.local` to in-cluster `https://keycloak.azul-infra.svc.cluster.local/...`. | **Baked** in `infra/values.yaml`, `infra/values-k3s-infra.yaml`, and `infra/scripts/configure-opensearch-security-azul.sh`. | No ad-hoc patch needed. |
| Dashboards trust for Keycloak OIDC | Added `opensearch_security.openid.root_ca` pointing at the mounted CA bundle. | **Baked** in values and the OpenSearch security script. | No ad-hoc patch needed, but the runtime CA bundle step above must run. |
| Dashboards OIDC 502 | Ingress-nginx returned `502 upstream sent too big header` after successful Keycloak login. Added larger proxy header buffers. | **Baked** in `infra/values.yaml` and `infra/values-k3s-infra.yaml`: `proxy-buffer-size: 16k`, `proxy-buffers-number: '8'`. | No ad-hoc annotation needed. If 502 returns, check ingress-nginx logs for the same message. |
| Keycloak OpenSearch admin roles | Token initially had group membership but not `opensearch-admins` in the `roles` claim. Added realm role and mapped it to the group. | **Baked** in `infra/scripts/configure-keycloak-azul.sh`; docs reference the script. | Run `infra/scripts/configure-keycloak-azul.sh` after Keycloak is ready. |
| OpenSearch OIDC role mappings | Mapped Keycloak/OIDC roles to OpenSearch roles and configured `roles_key: roles`. | **Baked** in `infra/values*.yaml` and `infra/scripts/configure-opensearch-security-azul.sh`. | Run the OpenSearch security script after Keycloak, OpenSearch, and restapi are ready. |
| Azul OpenSearch writer credentials | Azul was using `admin` or a mismatched writer password, causing 401s. Switched app config to `azul_writer` and aligned the committed default secret to `AzulWriter1!`. | **Baked** in `azul/values.yaml`, `azul/values-k3s-app.yaml`, `azul/creds.yaml`, and `azul/scripts/create-k3s-app-secrets.sh`; script also updates the live secret. | Apply `azul/creds.yaml` before Azul app deploy; run OpenSearch security script to create/update `azul_writer`. |
| OpenSearch bootstrap readiness | HTTP/authenticated readiness caused bootstrap catch-22. Changed probes to TCP checks. | **Baked** in infra values. | No ad-hoc patch needed. |
| OpenSearch Dashboards replicas | Operator default allowed unexpected replica count. Set replicas explicitly to 1. | **Baked** in infra template and values. | No ad-hoc scaling needed. |
| Hardcoded/generated TLS/CA material | Removed generated CA/TLS secrets from committed app creds; kept only non-certificate secrets. | **Baked**: generated certs are runtime-only; external Azul TLS is created by `scripts/create-azul-external-web-tls.sh`. | Run the TLS creation script before applying the Azul Argo app. Do not commit generated CA/private key material. |
| Explicit secret namespaces | Secrets were at risk of landing in the wrong namespace. | **Baked** in `infra/creds.yaml` and `azul/creds.yaml`. | No manual namespace patch needed. |
| Argo runtime CA drift | Argo showed/remediated diffs for runtime CA bundle keys. | **Baked** ignore rules in `argocd/azul-application.yaml` and `argocd/azul-infra-application.yaml`, including `RespectIgnoreDifferences=true`. | If Argo still reports OutOfSync only for runtime CA ConfigMaps, verify the app is Healthy and CA is mounted; do not commit runtime CA. |
| Keycloak password-grant testing | Temporarily used/checked direct token requests to inspect claims. | **Diagnostic only**. `configure-keycloak-azul.sh` sets `opensearch-dashboards` with `directAccessGrantsEnabled=false`. | Do not rely on password grant for Dashboards. Use browser OIDC flow. |
| Rancher 503/resource issue | Rancher was moved/sized/probe-tuned through its Helm release, outside the Azul app repo. | **Outside this repo**. Not part of Azul redeploy. | Keep Rancher Helm values in the cluster management notes/release; not required for Azul app clean redeploy. |

## Clean redeploy operational sequence

The canonical sequence remains `docs/deployment-start-to-finish.md`. The important
runtime/scripted points are:

1. Start from clean namespaces and Argo Applications.
2. Apply `infra/creds.yaml` and deploy `azul-infra` with Argo.
3. Wait for Keycloak, OpenSearch, OpenSearch Dashboards, MinIO, and Postgres.
4. Run `infra/scripts/configure-keycloak-azul.sh`.
5. Create Azul external TLS with `scripts/create-azul-external-web-tls.sh`.
6. Apply `azul/creds.yaml` and deploy `azul` with Argo.
7. Run `scripts/update-azul-app-ca-bundle.sh` and restart Azul pods so restapi
   trusts Keycloak/OpenSearch TLS.
8. After `restapi` is ready, run `infra/scripts/configure-opensearch-security-azul.sh`.
9. Run `scripts/update-azul-app-ca-bundle.sh` again if needed and restart
   `sts/restapi`, `deploy/ms-ingest-binary`, `deploy/ms-ingest-status`, and
   `deploy/ms-ageoff`.
10. Validate browser paths and in-pod TLS smoke tests.

## Quick validation commands

```bash
kubectl -n azul-infra get pods
kubectl -n azul-app get pods
kubectl -n argocd get applications.argoproj.io azul-infra azul

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

Expected: Keycloak returns `200`; OpenSearch returns `401` without auth, proving
TLS trust works.
