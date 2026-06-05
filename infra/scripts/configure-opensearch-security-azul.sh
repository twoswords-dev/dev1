#!/usr/bin/env bash
set -euo pipefail

# Configure OpenSearch security for Azul, following the Azul docs:
#   /docs/sysadmin-guide/installation/component-config/security_opensearch
#
# What this does:
# - runs Azul's own restapi helper to create/update azul_read, azul_write,
#   s-* and filler OpenSearch roles with the chart-current DLS query
# - creates/updates the internal azul_writer user
# - maps Keycloak/OIDC backend roles to OpenSearch roles
# - enables the OpenID Connect auth domain in OpenSearch security config
# - configures OpenSearch Dashboards for OIDC against the Keycloak client
#
# Defaults match the k3s homelab deployment.

INFRA_NAMESPACE="${INFRA_NAMESPACE:-azul-infra}"
AZUL_NAMESPACE="${AZUL_NAMESPACE:-azul-app}"
OPENSEARCH_SERVICE="${OPENSEARCH_SERVICE:-azul-opensearch}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
OPENSEARCH_LOCAL_PORT="${OPENSEARCH_LOCAL_PORT:-$((20000 + RANDOM % 20000))}"
OPENSEARCH_ADMIN_USER="${OPENSEARCH_ADMIN_USER:-}"
OPENSEARCH_ADMIN_PASSWORD="${OPENSEARCH_ADMIN_PASSWORD:-}"
AZUL_WRITER_USER="${AZUL_WRITER_USER:-azul_writer}"
AZUL_WRITER_PASSWORD="${AZUL_WRITER_PASSWORD:-AzulWriter1!}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.local}"
# URL used by in-cluster OpenSearch/OpenSearch Dashboards to fetch OIDC metadata.
# Do not use keycloak.local here: pod DNS does not know workstation hosts-file names.
KEYCLOAK_OIDC_URL="${KEYCLOAK_OIDC_URL:-https://keycloak.azul-infra.svc.cluster.local}"
KEYCLOAK_RESOLVE_IP="${KEYCLOAK_RESOLVE_IP:-192.168.10.111}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-azul}"
DASHBOARDS_CLIENT_ID="${DASHBOARDS_CLIENT_ID:-opensearch-dashboards}"
DASHBOARDS_URL="${DASHBOARDS_URL:-https://opensearch-dashboards.local}"
RESTAPI_POD_SELECTOR="${RESTAPI_POD_SELECTOR:-app=restapi}"
DASHBOARDS_CONFIGMAP="${DASHBOARDS_CONFIGMAP:-azul-opensearch-dashboards-config}"
DASHBOARDS_DEPLOYMENT="${DASHBOARDS_DEPLOYMENT:-azul-opensearch-dashboards}"
CA_BUNDLE_PATH="${CA_BUNDLE_PATH:-/usr/share/opensearch/config/certs/ca-certificates}"

command -v kubectl >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null

if [[ -z "$OPENSEARCH_ADMIN_USER" ]]; then
  OPENSEARCH_ADMIN_USER="$(kubectl -n "$INFRA_NAMESPACE" get secret azul-cluster-admincredentials -o jsonpath='{.data.username}' | base64 -d)"
fi
if [[ -z "$OPENSEARCH_ADMIN_PASSWORD" ]]; then
  OPENSEARCH_ADMIN_PASSWORD="$(kubectl -n "$INFRA_NAMESPACE" get secret azul-cluster-admincredentials -o jsonpath='{.data.password}' | base64 -d)"
fi
if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
  KEYCLOAK_ADMIN_PASSWORD="$(kubectl -n "$INFRA_NAMESPACE" get secret keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)"
fi

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPDIR:-}"
}
trap cleanup EXIT
TMPDIR="$(mktemp -d)"

keycloak_host="${KEYCLOAK_URL#https://}"
keycloak_host="${keycloak_host#http://}"
keycloak_host="${keycloak_host%%/*}"
KC_RESOLVE=()
if [[ -n "$KEYCLOAK_RESOLVE_IP" ]]; then
  KC_RESOLVE=(--resolve "${keycloak_host}:443:${KEYCLOAK_RESOLVE_IP}")
fi

kc_token() {
  curl -k -fsS "${KC_RESOLVE[@]}" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="$KEYCLOAK_ADMIN_USER" \
    --data-urlencode password="$KEYCLOAK_ADMIN_PASSWORD" \
    "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token
}
KC_TOKEN="$(kc_token)"

kc_get() {
  curl -k -fsS "${KC_RESOLVE[@]}" -H "Authorization: Bearer $KC_TOKEN" "$KEYCLOAK_URL$1"
}

get_client_uuid() {
  local client_id="$1"
  kc_get "/admin/realms/$KEYCLOAK_REALM/clients?clientId=$(printf '%s' "$client_id" | jq -sRr @uri)" | jq -r '.[0].id // empty'
}

get_client_secret() {
  local cid uuid
  cid="$1"
  uuid="$(get_client_uuid "$cid")"
  if [[ -z "$uuid" ]]; then
    echo "Keycloak client '$cid' not found. Run configure-keycloak-azul.sh first." >&2
    return 1
  fi
  kc_get "/admin/realms/$KEYCLOAK_REALM/clients/$uuid/client-secret" | jq -r .value
}

DASHBOARDS_CLIENT_SECRET="${DASHBOARDS_CLIENT_SECRET:-$(get_client_secret "$DASHBOARDS_CLIENT_ID") }"
DASHBOARDS_CLIENT_SECRET="${DASHBOARDS_CLIENT_SECRET% }"

# Ensure OpenSearch can trust Keycloak's local CA by appending azul-infra-ca to
# the CA bundle ConfigMap mounted at $CA_BUNDLE_PATH.
if kubectl -n "$INFRA_NAMESPACE" get cm azul-opensearch-certs >/dev/null 2>&1; then
  kubectl -n "$INFRA_NAMESPACE" get cm azul-opensearch-certs -o jsonpath='{.data.ca-certificates}' > "$TMPDIR/ca-certificates"
  kubectl -n "$INFRA_NAMESPACE" get secret azul-infra-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMPDIR/azul-infra-ca.crt"
  if ! grep -q 'CN = Azul Infra CA\|Azul Infra CA' "$TMPDIR/ca-certificates"; then
    {
      cat "$TMPDIR/ca-certificates"
      printf '\n# azul-infra-ca added by configure-opensearch-security-azul.sh\n'
      cat "$TMPDIR/azul-infra-ca.crt"
      printf '\n'
    } > "$TMPDIR/ca-certificates.new"
    kubectl -n "$INFRA_NAMESPACE" create configmap azul-opensearch-certs \
      --from-file=ca-certificates="$TMPDIR/ca-certificates.new" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

RESTAPI_POD="$(kubectl -n "$AZUL_NAMESPACE" get pod -l "$RESTAPI_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$RESTAPI_POD" ]]; then
  echo "No restapi pod found in $AZUL_NAMESPACE with selector $RESTAPI_POD_SELECTOR" >&2
  exit 1
fi

echo "Applying Azul-generated OpenSearch roles from $AZUL_NAMESPACE/$RESTAPI_POD ..."
kubectl -n "$AZUL_NAMESPACE" exec "$RESTAPI_POD" -- env \
  METASTORE_OPENSEARCH_ADMIN_USERNAME="$OPENSEARCH_ADMIN_USER" \
  METASTORE_OPENSEARCH_ADMIN_PASSWORD="$OPENSEARCH_ADMIN_PASSWORD" \
  azul-metastore apply-opensearch-config --no-input

kubectl -n "$INFRA_NAMESPACE" port-forward "svc/$OPENSEARCH_SERVICE" "$OPENSEARCH_LOCAL_PORT:$OPENSEARCH_PORT" >"$TMPDIR/port-forward.log" 2>&1 &
PF_PID=$!
pf_ready=false
for _ in $(seq 1 30); do
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "OpenSearch port-forward exited early:" >&2
    cat "$TMPDIR/port-forward.log" >&2 || true
    exit 1
  fi
  if curl -sk -u "$OPENSEARCH_ADMIN_USER:$OPENSEARCH_ADMIN_PASSWORD" "https://127.0.0.1:$OPENSEARCH_LOCAL_PORT" >/dev/null 2>&1; then
    pf_ready=true
    break
  fi
  sleep 1
done
if [[ "$pf_ready" != "true" ]]; then
  echo "OpenSearch port-forward did not become ready:" >&2
  cat "$TMPDIR/port-forward.log" >&2 || true
  exit 1
fi

os_api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -skfsS -u "$OPENSEARCH_ADMIN_USER:$OPENSEARCH_ADMIN_PASSWORD" \
      -X "$method" -H 'Content-Type: application/json' --data "$data" \
      "https://127.0.0.1:$OPENSEARCH_LOCAL_PORT$path"
  else
    curl -skfsS -u "$OPENSEARCH_ADMIN_USER:$OPENSEARCH_ADMIN_PASSWORD" \
      -X "$method" "https://127.0.0.1:$OPENSEARCH_LOCAL_PORT$path"
  fi
}

echo "Creating/updating internal user $AZUL_WRITER_USER ..."
os_api PUT "/_plugins/_security/api/internalusers/$AZUL_WRITER_USER" \
  "$(jq -nc --arg p "$AZUL_WRITER_PASSWORD" '{password:$p, backend_roles:["azul_write"], attributes:{}, opendistro_security_roles:[] }')" >/dev/null

put_mapping() {
  local role="$1" users_json="$2" backend_json="$3"
  os_api PUT "/_plugins/_security/api/rolesmapping/$role" \
    "$(jq -nc --argjson users "$users_json" --argjson backend "$backend_json" '{users:$users, backend_roles:$backend, hosts:[] }')" >/dev/null
}

echo "Creating/updating OpenSearch role mappings ..."
put_mapping azul_write "[\"$AZUL_WRITER_USER\"]" '["azul_write"]'
put_mapping azul_read '[]' '["azul_read","azul-access"]'
put_mapping s-any '[]' '["azul_read","azul-access"]'
put_mapping s-official '[]' '["azul_read","azul-access"]'
put_mapping s-tlp-clear '[]' '["azul_read","azul-access"]'
put_mapping s-tlp-green '[]' '["azul_read","azul-access"]'
put_mapping s-tlp-amber '[]' '["azul_read","azul-access"]'
put_mapping s-tlp-amber-strict '[]' '["azul_read","azul-access"]'
for r in azul-fill1 azul-fill2 azul-fill3 azul-fill4 azul-fill5; do
  put_mapping "$r" '[]' '["azul_read","azul-access"]'
done
# Give Keycloak opensearch-admins users administrative access in OpenSearch when the
# reserved all_access mapping is writable. Some operator installs forbid changing
# reserved mappings over the REST API, so do not fail the whole script here.
put_mapping all_access '[]' '["admin","opensearch-admins"]' || echo "WARN: could not update reserved all_access mapping; map opensearch-admins manually if needed" >&2

# OpenSearch securityconfig cannot normally be updated by HTTP basic admin.
# Use securityadmin.sh with the operator-created admin certificate.
echo "Applying OIDC auth domain to OpenSearch security config ..."
cat > "$TMPDIR/config.yml" <<EOF
_meta:
  type: "config"
  config_version: 2
config:
  dynamic:
    filtered_alias_mode: warn
    disable_rest_auth: false
    disable_intertransport_auth: false
    respect_request_indices_options: false
    kibana:
      multitenancy_enabled: true
      private_tenant_enabled: false
      default_tenant: ""
      server_username: "kibanaserver"
      index: ".kibana"
      sign_in_options:
        - BASIC
        - OPENID
    http:
      anonymous_auth_enabled: false
    authc:
      basic_internal_auth_domain:
        http_enabled: true
        transport_enabled: true
        order: 0
        http_authenticator:
          type: basic
          challenge: false
          config: {}
        authentication_backend:
          type: intern
          config: {}
      openid_auth_domain:
        http_enabled: true
        transport_enabled: true
        order: 1
        http_authenticator:
          type: openid
          challenge: false
          config:
            subject_key: preferred_username
            roles_key: roles
            openid_connect_url: "$KEYCLOAK_OIDC_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"
            openid_connect_idp.enable_ssl: true
            openid_connect_idp.verify_hostnames: true
            openid_connect_idp.pemtrustedcas_filepath: "$CA_BUNDLE_PATH"
        authentication_backend:
          type: noop
          config: {}
    authz: {}
    auth_failure_listeners: {}
    do_not_fail_on_forbidden: false
    multi_rolespan_enabled: true
    hosts_resolver_mode: ip-only
    do_not_fail_on_forbidden_empty: false
    on_behalf_of:
      enabled: false
EOF

OS_POD="$(kubectl -n "$INFRA_NAMESPACE" get pod -l opensearch.org/opensearch-cluster=azul-opensearch -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$INFRA_NAMESPACE" cp "$TMPDIR/config.yml" "$OS_POD:/tmp/azul-security-config.yml" -c opensearch
kubectl -n "$INFRA_NAMESPACE" get secret azul-opensearch-admin-certs -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMPDIR/admin.crt"
kubectl -n "$INFRA_NAMESPACE" get secret azul-opensearch-admin-certs -o jsonpath='{.data.tls\.key}' | base64 -d > "$TMPDIR/admin.key"
kubectl -n "$INFRA_NAMESPACE" cp "$TMPDIR/admin.crt" "$OS_POD:/tmp/admin.crt" -c opensearch
kubectl -n "$INFRA_NAMESPACE" cp "$TMPDIR/admin.key" "$OS_POD:/tmp/admin.key" -c opensearch
kubectl -n "$INFRA_NAMESPACE" exec "$OS_POD" -c opensearch -- sh -c \
  '/usr/share/opensearch/plugins/opensearch-security/tools/securityadmin.sh -f /tmp/azul-security-config.yml -t config -icl -nhnv -cacert /usr/share/opensearch/config/tls-transport/ca.crt -cert /tmp/admin.crt -key /tmp/admin.key -h 127.0.0.1 -p 9200'

# Update app-side metastore config/secret so Azul uses the purpose-built writer.
# The k3s Helm values should also set external.opensearch.username=azul_writer so
# Argo does not revert the ConfigMap after this runtime patch.
kubectl -n "$AZUL_NAMESPACE" patch configmap metastore --type merge \
  -p "$(jq -nc --arg u "$AZUL_WRITER_USER" '{data:{METASTORE_OPENSEARCH_USERNAME:$u}}')"
kubectl -n "$AZUL_NAMESPACE" create secret generic metastore-creds \
  --from-literal=writer="$AZUL_WRITER_PASSWORD" \
  --from-literal=jwt_signing_secret="$(kubectl -n "$AZUL_NAMESPACE" get secret metastore-creds -o jsonpath='{.data.jwt_signing_secret}' 2>/dev/null | base64 -d || openssl rand -base64 48 | tr -d '\n')" \
  --from-literal=opensearch_azul_security_password="$AZUL_WRITER_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Configure OpenSearch Dashboards for OIDC. This is a direct runtime patch to the
# operator-managed ConfigMap; keep matching values in infra Helm values later if
# you want Argo/Helm to own this declaratively.
echo "Configuring OpenSearch Dashboards OIDC ..."
cat > "$TMPDIR/opensearch_dashboards.yml" <<EOF
server.name: azul-opensearch-dashboards
server.host: 0.0.0.0
opensearch.ssl.verificationMode: none
opensearch.requestHeadersWhitelist: ["Authorization", "security_tenant", "securitytenant"]
opensearch_security.multitenancy.enabled: true
opensearch_security.multitenancy.tenants.preferred: ["Private", "Global"]
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
opensearch_security.cookie.secure: true
opensearch_security.auth.type: "openid"
opensearch_security.openid.scope: "openid profile email offline_access"
opensearch_security.openid.connect_url: "$KEYCLOAK_OIDC_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"
opensearch_security.openid.client_id: "$DASHBOARDS_CLIENT_ID"
opensearch_security.openid.client_secret: "$DASHBOARDS_CLIENT_SECRET"
opensearch_security.openid.base_redirect_url: "$DASHBOARDS_URL"
EOF
kubectl -n "$INFRA_NAMESPACE" create configmap "$DASHBOARDS_CONFIGMAP" \
  --from-file=opensearch_dashboards.yml="$TMPDIR/opensearch_dashboards.yml" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$INFRA_NAMESPACE" rollout restart deploy "$DASHBOARDS_DEPLOYMENT"

cat <<EOF
Configured OpenSearch security for Azul.

Azul OpenSearch writer:
  username: $AZUL_WRITER_USER
  password: $AZUL_WRITER_PASSWORD

Recommended Azul Helm value:
external:
  opensearch:
    username: "$AZUL_WRITER_USER"

OIDC issuer:
  $KEYCLOAK_URL/realms/$KEYCLOAK_REALM
Dashboards URL:
  $DASHBOARDS_URL
EOF
