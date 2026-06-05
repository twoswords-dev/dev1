# azul-infra

This Helm chart contains optional helpers for setting up infrastructure that Azul uses.
This reflects the required dependencies for a typical installation of Azul - if you don't
use this chart you need to provide these dependencies through an alternative mechanism.

These are example deployments and do not necessarily reflect the best possible deployment
for a particular product - subsequently, a production deployment of Azul should consider
whether managed cloud services are suitable for use (such as hosted OpenSearch, S3, etc.).

Product deployments included:

- OpenSearch
- Minio
- Kafka

By default, this chart will deploy everything (for a turn-key solution), but individual
components can be disabled as required, particularly if you have better alternatives for
one or more products above.

You must read through all below steps for a successful deployment as human intervention
is required for several steps.

## Configuring

### Kafka

Kafka is required to store events stored in the system. The infrastructure chart utilises
Strimzi to orchestrate the deployment of Kafka and enables rolling upgrades & other sysadmin
functionality.

Requirements:

- The Strimzi operator must be installed before the Kafka custom resources reconcile.
- This chart can install Strimzi as part of the same Helm/Argo CD deployment by setting:

```yaml
operators:
  strimzi:
    enabled: true

strimzi-operator:
  watchNamespaces:
    - <infra namespace>
  watchAnyNamespace: false
  labelsExclusionPattern: argocd.argoproj.io/instance
```

  - `labelsExclusionPattern` is required when using Argo CD. Without it, Strimzi can copy
    Argo CD labels to generated PVCs and Argo CD may try to prune them.
  - Set `watchAnyNamespace: true` only if the operator must watch every namespace. Otherwise,
    prefer `watchNamespaces` with the namespace where this infra chart is deployed.
- If you install Strimzi outside this chart, configure the equivalent operator environment:
  - `STRIMZI_LABELS_EXCLUSION_PATTERN=argocd.argoproj.io/instance`
  - `STRIMZI_NAMESPACE=<infra namespace>` or `STRIMZI_NAMESPACE=*`

For upgrades of Kafka, refer to the Strimzi documentation for version and compatibility guidance: https://strimzi.io/

### Minio

Minio is an example storage provider used to store the content of files uploaded to Azul. The
configuration of Minio in this chart is not designed for production use (primarily because
of the lack of replication & spreading of workloads across regions), and if you intend to
deploy in production you need to utilise a storage configuration suitable for this (such as
a replicated Minio install, Amazon S3 or Azure Blob Storage).

Requirements:

- Kubernetes secrets configured with the following:
  - s3-keys:
    - accesskey: An access key used for Minio access.
    - secretkey: A Minio secret key.
  - s3-backup-keys:
    - accesskey: An access key used for Minio access.
    - secretkey: A Minio secret key.

### OpenSearch

OpenSearch is used to index and collate documents emitted from various components in Azul for
use by clients and the UI. This deployment utilises the OpenSearch Operator for automatic
management of the tool.

- Requires Cert Manager to be installed in the cluster.
- This will automatically provision a self-signed CA for the purposes of inter-node
  communication and for the internal service. You can also supply your own Cert Manager
  CA if you have one available.
- Install the OpenSearch Operator (if you haven't disabled OpenSearch). This chart can install
  it as part of the same Helm/Argo CD deployment by setting:

```yaml
operators:
  opensearch:
    enabled: true

opensearch-operator:
  installCRDs: true
  manager:
    watchNamespace: <infra namespace>
```

  Alternatively, install it outside this chart:

  ```bash
  helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
  helm install opensearch-operator opensearch-operator/opensearch-operator
  ```

  - To upgrade for OpenSearch 3.x or later, run a Helm upgrade:

    ```bash
    helm upgrade opensearch-operator opensearch-operator/opensearch-operator
    ```

- Setup the following secrets:
  - azul-cluster-dashboardcredentials
    Username/password combination containing credentials matching internalUsers (see
    values.yaml for an example)
  - azul-cluster-admincredentials

For example:

```yaml
# creds.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: azul-cluster-admincredentials
type: Opaque
data:
  # admin
  username: YWRtaW4=
  # adminpassword
  password: YWRtaW5wYXNzd29yZA==

---
apiVersion: v1
kind: Secret
metadata:
  name: azul-cluster-dashboardcredentials
type: Opaque
data:
  # kibanaserver
  username: a2liYW5hc2VydmVy
  # kibanaserverpassword
  password: a2liYW5hc2VydmVycGFzc3dvcmQ=
```

Apply with:

```bash
kubectl apply -f creds.yaml
```

The committed `creds.yaml` uses explicit `azul-infra` namespaces so secrets are
created where the chart/operator expects them. OpenSearch Dashboards starts with
basic auth during bootstrap; OIDC is enabled later by
`infra/scripts/configure-opensearch-security-azul.sh`. Its Ingress includes
larger nginx proxy header buffers for OIDC callback/session headers.

- After activating the Helm chart, ensure Azul application pods trust the CA that
  issued OpenSearch and Keycloak certificates. In the Azul core chart this is the
  ConfigMap named by `CACertificateConfigMap` (for k3s: `azul-ca-bundle` in
  `azul/values-k3s-app.yaml`). The ConfigMap key is `ca.crt` and pods mount it as
  `/cafile/ca.crt`.

  For this k3s install the relevant issuer CA is normally in:

  ```bash
  kubectl -n azul-infra get secret azul-infra-ca -o jsonpath='{.data.ca\.crt}' | base64 -d
  ```

  For local/k3s rebuilds, patch the live app CA-bundle ConfigMap after the Azul
  app is synced:

  ```bash
  scripts/update-azul-app-ca-bundle.sh
  kubectl -n azul-app rollout restart deploy,sts
  ```

  The Argo CD `azul` Application ignores `/data/ca.crt` on `azul-ca-bundle` so
  this runtime-generated CA is not removed by self-heal. Do not commit generated
  cluster CA material into `azul/ca-certificates`.

The k3s OpenSearch node startup and readiness probes initially check only that
localhost port 9200 is listening. This publishes the OpenSearch service endpoint
before the security index exists, allowing the operator securityadmin job to
initialize the cluster. Do not make readiness depend on authenticated HTTP until
after bootstrap.

**IMPORTANT**: The OpenSearch Operator does not currently support hot
certificate rotation. While Cert Manager will automatically
generate new certificates on expiry, these will not be
reflected by running nodes until a restart.

In order to update certificates, _delete_ the pods that the OpenSearch
cluster uses. This will cause the cluster to be completely shut down and restarted
with the updated certs. Performing a rolling restart is unlikely to work as nodes
with old/new certificates will be unable to communicate.

FUTURE: CA bundle generation should be done by a sidecar or an init container or
something, remove the above instructions.

#### Opensearch Updates

First update your opensearch operator (add a namespace to the command as appropriate)

```bash
helm repo update opensearch-operator
helm upgrade opensearch-operator opensearch-operator/opensearch-operator
```

Next update the version of Opensearch in `values.yaml`

### Keycloak

This is a demo for what authentication could look like in a typical Azul
deployment. If you have other OIDC systems available we strongly recommend
that you use those services instead.

This requires a Keycloak secret:

- keycloak:
  - DB_PASSWORD: Database password for Postgres.
  - KEYCLOAK_ADMIN_PASSWORD: Console admin password.

You will need to manually setup Keycloak with a client for Azul to use, as well
as users, etc.

### Prometheus and Grafana

Prometheus and Grafana are deployed using the `kube-prometheus-stack` [chart](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack).

Ensure an appropriate namespace is selected to install Prometheus and Grafana using `namespaceOverride`.

```yaml
kube-prometheus-stack:
  enable: true
  namespaceOverride: "monitoring"
```

#### Grafana

`grafana.grafana.ini` provides Grafana's primary configuration.

It is recommended to overwrite the following:

```yaml
grafana:
  grafana.ini:
    server:
      domain: monitoring.example.com
      root_url: "https://monitoring.example.com"
    unified_alerting:
      enabled: true
    alerting:
      enabled: false
    # Grafana provides a basic authentication system with password authentication enabled by default
    auth.basic:
      enabled: true
```

It is recommended to disable `auth.basic` and connect to a supported IAM solution in your environment based on the following documentation: https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/

If you are using Basic authentication, it is recommended to create a secret containing the `admin-user` and `admin-password` and add the following to values.yaml

```yaml
grafana:
  admin:
    # The name of an existing secret containing the admin credentials
    existingSecret: prometheus-grafana
    # The key in the existing admin secret containing the username
    userKey: admin-user
    # The key in the existing admin secret containing the password
    passwordKey: admin-password
```

Persistence for Grafana can be configured using the following:

```yaml
grafana:
  # To make Grafana persistent (Using Statefulset)
  persistence:
    type: pvc
    enabled: true
    storageClassName: default
    accessModes:
      - ReadWriteOnce
    size: 10Gi
    finalizers:
      - kubernetes.io/pvc-protection
```

Ensure Prometheus and Loki (if enabled) are connected as datasources for Grafana. The configuration uses internal cluster services

```yaml
# Configure grafana datasources
# ref: http://docs.grafana.org/administration/provisioning/#datasources
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        url: http://prometheus-kube-prometheus-prometheus:9090
        access: proxy
        isDefault: true
      - name: Loki
        uid: loki
        type: loki
        url: http://loki:3100
        access: proxy
        isDefault: false
```

Further details for Grafana configuration are detailed in the following README: https://github.com/grafana/helm-charts/blob/main/charts/grafana/README.md

#### Prometheus

Ensure the `prometheus.ingress` is correctly configured and reflected in `prometheus.prometheusSpec`.

Retention for Prometheus can be increased from the default of 10 days using `prometheus.prometheusSpec.retention`

#### Alertmanager

Alertmanager is disabled by default, it can be enabled by setting the following and configuring `alertmanager.receivers`

```yaml
kube-prometheus-stack:
  alertmanager:
    enabled: true
```

#### Blackbox Exporter

Ensure blackbox exporter is configured with a CA certificate required to contact services using `prometheus-blackbox-exporter.extraConfigmapMounts`.

Example:

```yaml
extraConfigmapMounts:
  - name: certs-configmap
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca-certificates.crt # (optional)
    configMap: certs-configmap
    readOnly: true
    defaultMode: 420
```

### Loki

Loki is deployed for Azul log aggregation. Logs from Azul components such as the `restapi` are forwarded to Loki using Promtail sidecars.
Loki is deployed as a single binary for simplicity, this is suitable for tens of GB of logs per day.
