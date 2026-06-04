# Azul airgap deployment profile

This branch contains an airgap profile for a larger k3s cluster using `*.internal.au` DNS and a private registry named `registry-1.docker.io`.

## Included bundle items

- Helm dependency charts: `airgap/charts/*.tgz` and `infra/charts/*.tgz`
- Target image manifest: `airgap/images/images.txt`
- Source-to-private-registry image map: `airgap/images/images-map.tsv`
- Image bundle helper scripts: `airgap/images/pull-save-images.sh`, `load-images.sh`, `push-images.sh`
- Airgap Helm values: `infra/values-airgap.yaml`, `azul/values-airgap.yaml`
- Argo CD apps: `argocd/azul-infra-airgap-application.yaml`, `argocd/azul-airgap-application.yaml`

## Capacity profile

- OpenSearch: 3 data/cluster-manager nodes, 2Ti each, 6Gi/3 CPU requested per node, 8Gi/6 CPU limit per node, JVM heap fixed at `-Xms4g -Xmx4g`.
- Kafka: 3 brokers/controllers, 1Ti each, replication factor 3, min ISR 2.
- MinIO: 3 replicas, 5Ti requested storage.
- Keycloak: 2 replicas; Postgres PVC 100Gi.
- Azul app: HA web/restapi/metastore/dispatcher settings with HPA ranges raised.

## Prepare image archives on a connected host

```bash
cd /data/azul-app
./airgap/images/pull-save-images.sh
```

Copy the repo, including `airgap/images/archives/`, to the airgapped site. If the private registry is reachable from the staging host, push directly:

```bash
./airgap/images/push-images.sh
```

Otherwise load/push from inside the airgapped environment after logging in to `registry-1.docker.io`.

## Deploy

1. Ensure k3s has an ingress controller, Longhorn/storage class `longhorn`, cert-manager CRDs/controller, and Argo CD installed.
2. Ensure DNS resolves:
   - `azul.internal.au`
   - `keycloak.internal.au`
   - `opensearch-dashboards.internal.au`
   - `minio.internal.au`
   - `minio-api.internal.au`
3. Create namespaces and secrets:

```bash
kubectl create namespace azul-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace azul-app --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f infra/creds.yaml
kubectl apply -f azul/creds.yaml
```

4. Create/update the external Azul web TLS secret with a certificate covering `azul.internal.au`:

```bash
AZUL_HOSTNAME=azul.internal.au \
TLS_CERT_FILE=/path/to/fullchain.crt \
TLS_KEY_FILE=/path/to/tls.key \
scripts/create-azul-external-web-tls.sh
```

5. Deploy infra with Argo CD, then wait at least for Keycloak. Do not wait for full infra health before Keycloak setup: OpenSearch Dashboards may remain pending until `opensearch-dashboards-oidc` exists.

```bash
kubectl apply -f argocd/azul-infra-airgap-application.yaml
kubectl -n azul-infra wait --for=condition=Ready pod -l app=keycloak --timeout=300s
```

6. Configure Keycloak. The Keycloak script also creates/updates `azul-infra/opensearch-dashboards-oidc`, which OpenSearch Dashboards uses for its OIDC client secret:

```bash
KEYCLOAK_URL=https://keycloak.internal.au \
AZUL_URL=https://azul.internal.au \
OPENSEARCH_DASHBOARDS_URL=https://opensearch-dashboards.internal.au \
infra/scripts/configure-keycloak-azul.sh
```

7. Deploy Azul, then configure OpenSearch security after OpenSearch, Keycloak, and the Azul restapi are ready:

```bash
kubectl apply -f argocd/azul-airgap-application.yaml
kubectl -n argocd get applications.argoproj.io azul-airgap -w
infra/scripts/configure-opensearch-security-azul.sh
```

This profile was rendered and reviewed locally but intentionally not deployed to the small homelab cluster.
