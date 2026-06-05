# Airgap 2.0 scaled deployment profile

This branch/profile keeps the working `main` deployment fixes and adds a scaled
airgapped profile for a larger cluster.

Branch:

```text
airgap-2.0
```

Values overlays:

```text
infra/values-airgap.yaml
azul/values-airgap.yaml
```

Argo CD Applications on this branch are configured to use:

```yaml
source:
  targetRevision: airgap-2.0
  helm:
    valueFiles:
      - values.yaml
      - values-airgap.yaml
```

## Capacity target

The profile assumes a larger airgapped cluster with approximately:

```text
80 CPU cores
100 GiB RAM
Longhorn-backed persistent storage
```

The values are intentionally conservative enough to fit alongside Kubernetes,
Longhorn, ingress, and monitoring overhead, but much larger than the homelab
single-replica profile.

## Major scaling changes

### OpenSearch

OpenSearch is scaled to a three-node cluster:

```yaml
opensearch:
  general:
    replicas: 3
  nodes:
    diskSize: 100Gi
    resources:
      requests:
        cpu: 4000m
        memory: 8Gi
      limits:
        cpu: 8000m
        memory: 12Gi
```

The airgap overlay also sets:

```yaml
cluster.initial_master_nodes: azul-opensearch-nodes-0,azul-opensearch-nodes-1,azul-opensearch-nodes-2
discovery.seed_hosts: azul-opensearch-nodes-0,azul-opensearch-nodes-1,azul-opensearch-nodes-2
OPENSEARCH_JAVA_OPTS: -Xms6g -Xmx6g
```

OpenSearch Dashboards is scaled to two replicas and keeps the OIDC/header-buffer
fixes from `main`.

### MinIO

Primary MinIO is scaled for larger airgapped storage:

```yaml
minio:
  main:
    replicas: 4
    requests:
      storage: 100Gi
```

Backup MinIO is enabled and similarly sized:

```yaml
minio:
  backup:
    enable: true
    replicas: 4
    requests:
      storage: 100Gi
```

### Kafka

Kafka is scaled to three replicas with larger disks and production-style
replication settings:

```yaml
kafka:
  replicas: 3
  storage:
    size: 100Gi
  clusterConfig:
    offsets.topic.replication.factor: 3
    transaction.state.log.replication.factor: 3
    transaction.state.log.min.isr: 2
    default.replication.factor: 3
    min.insync.replicas: 2
    unclean.leader.election.enable: false
```

### Keycloak/Postgres

Keycloak is scaled to three replicas. Its Postgres PVC is increased to 50Gi.

```yaml
keycloak:
  replicas: 3
  postgres:
    size: 50Gi
```

### Azul app

The Azul app overlay increases HPA ranges, dispatcher replicas, metastore worker
replicas, REST API replicas, and persistent volume sizes.

Notable changes:

```yaml
coreHPA:
  minReplicas: 2
  maxReplicas: 6
pluginHPA:
  minReplicas: 2
  maxReplicas: 10
restapi:
  minReplicas: 3
  maxReplicas: 8
  logPvcSize: 50Gi
  purgePvcSize: 100Gi
redis:
  pvcSize: 20Gi
```

Metastore OpenSearch index defaults are adjusted for a three-node OpenSearch
cluster:

```yaml
metastore:
  status_index:
    number_of_shards: 3
    number_of_replicas: 1
  plugin_index:
    number_of_shards: 3
    number_of_replicas: 1
```

## Airgap image/registry placeholders

Image and registry overrides are intentionally **commented out** for now in the
airgap values files. Fill them in only after the internal registry path and image
mirror names are known.

Files with placeholders:

```text
infra/values-airgap.yaml
azul/values-airgap.yaml
```

Examples are included for:

```text
imagePullSecrets
MinIO image
Keycloak image
Kafka helper image
Azul dispatcher/restapi/webui/docs images
Redis image
```

## Main fixes preserved

Because this branch starts from `main`, it includes the same fixes and docs:

- no committed generated TLS/CA secrets
- explicit namespaces in creds
- cert-manager runtime CA bootstrap flow
- `scripts/create-azul-external-web-tls.sh`
- `scripts/update-azul-app-ca-bundle.sh`
- OpenSearch TCP bootstrap probes
- OpenSearch OIDC security config
- in-cluster Keycloak OIDC URLs for pods
- Dashboards Keycloak CA trust
- Dashboards ingress header-buffer fix for OIDC login
- `azul_writer` OpenSearch user/password alignment
- Argo runtime CA ignore rules
- company TLS and homelab TLS docs

## Render validation

Before deploying, render both charts with the airgap overlays:

```bash
helm template azul-infra ./infra \
  -f infra/values.yaml \
  -f infra/values-airgap.yaml \
  --namespace azul-infra >/tmp/infra-airgap.yaml

helm template azul ./azul \
  -f azul/values.yaml \
  -f azul/values-airgap.yaml \
  --namespace azul-app >/tmp/azul-airgap.yaml
```

## Clean redeploy notes

Use the same clean deployment order as `docs/deployment-start-to-finish.md`, but
apply the Argo Application manifests from branch `airgap-2.0` so Argo uses the
airgap overlays.

The runtime steps are still required:

```bash
infra/scripts/configure-keycloak-azul.sh
infra/scripts/configure-opensearch-security-azul.sh
scripts/create-azul-external-web-tls.sh
scripts/update-azul-app-ca-bundle.sh
kubectl -n azul-app rollout restart sts/restapi deploy/ms-ingest-binary deploy/ms-ingest-status deploy/ms-ageoff
```

Do not commit generated company/local TLS material or private keys.
