# k3s Azul infra rollout

This is the first-pass infra configuration for the local k3s cluster.

Target namespaces:

- Infra chart: `azul-infra`
- Azul app later: `azul`

## What this config does

Use `infra/values-k3s-infra.yaml` with the `infra` Helm chart.

It enables the runtime dependencies first, sized for the small k3s cluster:

- Strimzi Operator, namespace-scoped to `azul-infra`, with Argo CD label exclusion enabled
- OpenSearch Operator, namespace-scoped to `azul-infra`, with CRDs installed by Helm
- cert-manager namespace-local CA/Issuer: `azul-infra-ca`
- OpenSearch with cert-manager-issued internal TLS certs, 1 data node, 15Gi disk, 1Gi request / 1536Mi limit
- Keycloak with cert-manager-issued HTTPS certs on the pod/service, 1 replica, 512Mi request / 1Gi limit
- Postgres for Keycloak, 5Gi disk, 256Mi request / 512Mi limit
- Kafka via Strimzi, 1 broker/controller, 10Gi disk, 1Gi request / 1536Mi limit, replication factors set to 1
- MinIO main store, 1 replica, 10Gi disk, 256Mi request / 512Mi limit
- MinIO backup store disabled initially to conserve disk/RAM

Monitoring/logging dependencies are intentionally disabled for the first rollout:

- kube-prometheus-stack
- Loki
- blackbox exporter
- pushgateway

They can be enabled after OpenSearch/Kafka/MinIO/Keycloak are healthy.

## Required cluster prerequisites

cert-manager must be installed before this chart is synced. This cluster already has the cert-manager CRDs.

The infra chart now includes the Strimzi and OpenSearch Operator Helm charts as optional dependencies, enabled by `values-k3s-infra.yaml`.

If Argo CD reports a dry-run error for newly-created CRDs on first sync, retry the sync after the CRDs are established, or set `SkipDryRunOnMissingResource=true` on the Argo CD application.

## One-time secrets

Do not commit live secrets. Create them in the cluster before syncing with Argo CD:

```bash
cd infra
./scripts/create-k3s-infra-secrets.sh
```

To supply your own passwords, set env vars before running the script, for example:

```bash
export KEYCLOAK_ADMIN_PASSWORD='change-me'
export OPENSEARCH_ADMIN_PASSWORD='adminpassword'
./scripts/create-k3s-infra-secrets.sh
```

## Argo CD UI settings

Create an app from the Argo CD UI with roughly:

- Repository URL: `http://192.168.10.126:3000/twoswords/azul.git`
- Revision: this feature branch until merged
- Path: `infra`
- Values file: `values-k3s-infra.yaml`
- Destination cluster: in-cluster
- Destination namespace: `azul-infra`
- Sync option: create namespace if needed

## Windows hosts entries

The k3s ingress-nginx LoadBalancer currently advertises `192.168.10.111`, `192.168.10.112`, and `192.168.10.113`. Add entries like these to your Windows hosts file, using any one of those ingress IPs:

```text
192.168.10.111 keycloak.local
192.168.10.111 opensearch-dashboards.local
192.168.10.111 minio.local
192.168.10.111 minio-api.local
```

Configured ingress URLs from `values-k3s-infra.yaml`:

- Keycloak: `https://keycloak.local`
- OpenSearch Dashboards: `https://opensearch-dashboards.local`
- MinIO console: `https://minio.local`
- MinIO S3 API: `https://minio-api.local`

The OpenSearch API itself is intentionally not exposed through ingress in this small-cluster profile; Azul should use the in-cluster service endpoint.

## Notes for Azul app rollout later

After infra is healthy, the Azul app namespace `azul` should trust the CA stored in:

```text
namespace: azul-infra
secret: azul-infra-ca
key: ca.crt
```

That CA should be copied or bundled into the Azul app CA config before enabling Azul connectivity to OpenSearch/Keycloak/MinIO/Kafka.
