#!/usr/bin/env bash
set -euo pipefail

# Configure the Azul realm, users, client scopes and clients in the Keycloak
# instance deployed by the Azul infra chart.
#
# Defaults are for the k3s homelab deployment:
#   Keycloak: https://keycloak.local
#   Azul UI:  https://azul.local
#   OpenSearch Dashboards: https://opensearch-dashboards.local
#
# Requirements on the machine running this script: kubectl, curl, jq, openssl.

NAMESPACE="${NAMESPACE:-azul-infra}"
AZUL_NAMESPACE="${AZUL_NAMESPACE:-azul-app}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.local}"
KEYCLOAK_RESOLVE_IP="${KEYCLOAK_RESOLVE_IP:-192.168.10.111}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
REALM="${REALM:-azul}"
AZUL_URL="${AZUL_URL:-https://azul.local}"
OPENSEARCH_DASHBOARDS_URL="${OPENSEARCH_DASHBOARDS_URL:-https://opensearch-dashboards.local}"
BASIC_USER="${BASIC_USER:-basic}"
BASIC_PASSWORD="${BASIC_PASSWORD:-AzulBasic1!}"
OPENSEARCH_ADMIN_USER="${OPENSEARCH_ADMIN_USER:-opensearch-admin}"
OPENSEARCH_ADMIN_PASSWORD="${OPENSEARCH_ADMIN_PASSWORD:-OpenSearchAdmin1!}"
SERVICE_CLIENT_ID="${SERVICE_CLIENT_ID:-azul-service}"
CREATE_AZUL_SERVICE_SECRET="${CREATE_AZUL_SERVICE_SECRET:-true}"

command -v kubectl >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null
command -v openssl >/dev/null

if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
  KEYCLOAK_ADMIN_PASSWORD="$(kubectl -n "$NAMESPACE" get secret keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)"
fi

CURL_RESOLVE=()
if [[ -n "$KEYCLOAK_RESOLVE_IP" ]]; then
  host="${KEYCLOAK_URL#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  CURL_RESOLVE=(--resolve "${host}:443:${KEYCLOAK_RESOLVE_IP}")
fi

kc_token() {
  curl -k -fsS "${CURL_RESOLVE[@]}" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="$KEYCLOAK_ADMIN_USER" \
    --data-urlencode password="$KEYCLOAK_ADMIN_PASSWORD" \
    "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token
}

TOKEN="$(kc_token)"

kc() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -k -fsS "${CURL_RESOLVE[@]}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data" \
      "$KEYCLOAK_URL$path"
  else
    curl -k -fsS "${CURL_RESOLVE[@]}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      "$KEYCLOAK_URL$path"
  fi
}

kc_allow_conflict() {
  local method="$1" path="$2" data="${3:-}"
  local status body
  body="$(mktemp)"
  if [[ -n "$data" ]]; then
    status="$(curl -k -sS "${CURL_RESOLVE[@]}" -o "$body" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data" \
      "$KEYCLOAK_URL$path")"
  else
    status="$(curl -k -sS "${CURL_RESOLVE[@]}" -o "$body" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      "$KEYCLOAK_URL$path")"
  fi
  if [[ "$status" =~ ^2|409$ ]]; then
    rm -f "$body"
    return 0
  fi
  cat "$body" >&2
  rm -f "$body"
  echo "Keycloak API call failed: $method $path HTTP $status" >&2
  return 1
}

url_no_slash() { printf '%s' "${1%/}"; }

get_group_id() {
  local name="$1"
  kc GET "/admin/realms/$REALM/groups?search=$(printf '%s' "$name" | jq -sRr @uri)" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1
}

get_client_id() {
  local client_id="$1"
  kc GET "/admin/realms/$REALM/clients?clientId=$(printf '%s' "$client_id" | jq -sRr @uri)" | jq -r '.[0].id // empty'
}

get_client_scope_id() {
  local name="$1"
  kc GET "/admin/realms/$REALM/client-scopes" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1
}

ensure_realm() {
  kc_allow_conflict POST /admin/realms "$(jq -nc --arg r "$REALM" '{realm:$r, enabled:true, displayName:$r}')"
}

ensure_role() {
  local role="$1"
  kc_allow_conflict POST "/admin/realms/$REALM/roles" "$(jq -nc --arg r "$role" '{name:$r}')"
}

ensure_group() {
  local group="$1"
  if [[ -z "$(get_group_id "$group")" ]]; then
    kc_allow_conflict POST "/admin/realms/$REALM/groups" "$(jq -nc --arg g "$group" '{name:$g}')"
  fi
}

assign_role_to_group() {
  local role="$1" group="$2" gid role_json
  gid="$(get_group_id "$group")"
  role_json="$(kc GET "/admin/realms/$REALM/roles/$role")"
  kc_allow_conflict POST "/admin/realms/$REALM/groups/$gid/role-mappings/realm" "[$role_json]"
}

ensure_user() {
  local user="$1" pass="$2" existing uid
  existing="$(kc GET "/admin/realms/$REALM/users?username=$(printf '%s' "$user" | jq -sRr @uri)&exact=true" | jq -r '.[0].id // empty')"
  if [[ -z "$existing" ]]; then
    kc_allow_conflict POST "/admin/realms/$REALM/users" "$(jq -nc --arg u "$user" --arg e "$user@example.local" '{username:$u, email:$e, firstName:$u, lastName:"User", enabled:true, emailVerified:true, requiredActions:[] }')"
    existing="$(kc GET "/admin/realms/$REALM/users?username=$(printf '%s' "$user" | jq -sRr @uri)&exact=true" | jq -r '.[0].id')"
  fi
  uid="$existing"
  kc PUT "/admin/realms/$REALM/users/$uid" "$(jq -nc --arg u "$user" --arg e "$user@example.local" '{username:$u, email:$e, firstName:$u, lastName:"User", enabled:true, emailVerified:true, requiredActions:[] }')" >/dev/null
  kc PUT "/admin/realms/$REALM/users/$uid/reset-password" "$(jq -nc --arg p "$pass" '{type:"password", value:$p, temporary:false}')" >/dev/null
}

add_user_to_group() {
  local user="$1" group="$2" uid gid
  uid="$(kc GET "/admin/realms/$REALM/users?username=$(printf '%s' "$user" | jq -sRr @uri)&exact=true" | jq -r '.[0].id')"
  gid="$(get_group_id "$group")"
  kc PUT "/admin/realms/$REALM/users/$uid/groups/$gid" >/dev/null
}

ensure_scope() {
  local scope="$1"
  if [[ -z "$(get_client_scope_id "$scope")" ]]; then
    kc_allow_conflict POST "/admin/realms/$REALM/client-scopes" "$(jq -nc --arg s "$scope" '{name:$s, protocol:"openid-connect"}')"
  fi
}

ensure_mapper() {
  local scope="$1" name="$2" mapper_type="$3" config_json="$4" sid mid
  sid="$(get_client_scope_id "$scope")"
  mid="$(kc GET "/admin/realms/$REALM/client-scopes/$sid/protocol-mappers/models" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1)"
  payload="$(jq -nc --arg n "$name" --arg p "$mapper_type" --argjson c "$config_json" '{name:$n, protocol:"openid-connect", protocolMapper:$p, config:$c}')"
  if [[ -n "$mid" ]]; then
    # Keycloak can return 500 when replacing some mapper types without the full
    # server-side model. Delete/recreate is deterministic and idempotent enough.
    kc DELETE "/admin/realms/$REALM/client-scopes/$sid/protocol-mappers/models/$mid" >/dev/null
  fi
  kc POST "/admin/realms/$REALM/client-scopes/$sid/protocol-mappers/models" "$payload" >/dev/null
}

ensure_client() {
  local client_id="$1" public="$2" standard="$3" direct="$4" service="$5" root="$6" id payload
  root="$(url_no_slash "$root")"
  id="$(get_client_id "$client_id")"
  payload="$(jq -nc \
    --arg cid "$client_id" --arg root "$root" \
    --argjson public "$public" --argjson standard "$standard" --argjson direct "$direct" --argjson service "$service" \
    '{clientId:$cid, name:$cid, enabled:true, protocol:"openid-connect", alwaysDisplayInConsole:true,
      publicClient:$public, standardFlowEnabled:$standard, directAccessGrantsEnabled:$direct,
      serviceAccountsEnabled:$service, authorizationServicesEnabled:false,
      rootUrl:($root+"/"), baseUrl:($root+"/"), adminUrl:($root+"/"), redirectUris:[($root+"/*")], webOrigins:["+"]}')"
  if [[ -n "$id" ]]; then
    kc PUT "/admin/realms/$REALM/clients/$id" "$payload" >/dev/null
  else
    kc POST "/admin/realms/$REALM/clients" "$payload" >/dev/null
  fi
}

add_default_scope_to_client() {
  local client_id="$1" scope="$2" cid sid
  cid="$(get_client_id "$client_id")"
  sid="$(get_client_scope_id "$scope")"
  kc_allow_conflict PUT "/admin/realms/$REALM/clients/$cid/default-client-scopes/$sid"
}

client_secret() {
  local client_id="$1" cid
  cid="$(get_client_id "$client_id")"
  kc GET "/admin/realms/$REALM/clients/$cid/client-secret" | jq -r .value
}

AZUL_ROOT="$(url_no_slash "$AZUL_URL")"
OSD_ROOT="$(url_no_slash "$OPENSEARCH_DASHBOARDS_URL")"

ensure_realm

for role in azul-access REL:APPLE; do
  ensure_role "$role"
done

for group in general opensearch-admins azul_reader; do
  ensure_group "$group"
done

# Give normal Azul users the Azul access role. The azul_reader group is included
# for deployments that sync/federate an external Azul reader group name.
assign_role_to_group azul-access general
assign_role_to_group azul-access azul_reader
assign_role_to_group REL:APPLE general

ensure_user "$BASIC_USER" "$BASIC_PASSWORD"
ensure_user "$OPENSEARCH_ADMIN_USER" "$OPENSEARCH_ADMIN_PASSWORD"
add_user_to_group "$BASIC_USER" general
add_user_to_group "$OPENSEARCH_ADMIN_USER" general
add_user_to_group "$OPENSEARCH_ADMIN_USER" opensearch-admins

ensure_scope azul
ensure_mapper azul realm-role-mapper oidc-usermodel-realm-role-mapper \
  '{"claim.name":"roles","jsonType.label":"String","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true"}'

ensure_scope audience
ensure_mapper audience web-audience oidc-audience-mapper \
  '{"included.client.audience":"azul-web","access.token.claim":"true","id.token.claim":"false"}'

ensure_scope azul-service-cs
ensure_mapper azul-service-cs azul-access oidc-hardcoded-role-mapper \
  '{"role":"azul-access","access.token.claim":"true","id.token.claim":"true"}'

ensure_client azul-web true true true false "$AZUL_ROOT"
add_default_scope_to_client azul-web azul
add_default_scope_to_client azul-web audience

ensure_client opensearch-dashboards false true false false "$OSD_ROOT"
add_default_scope_to_client opensearch-dashboards azul
add_default_scope_to_client opensearch-dashboards audience

ensure_client "$SERVICE_CLIENT_ID" false true true true "$AZUL_ROOT"
add_default_scope_to_client "$SERVICE_CLIENT_ID" azul
add_default_scope_to_client "$SERVICE_CLIENT_ID" azul-service-cs
add_default_scope_to_client "$SERVICE_CLIENT_ID" audience
SERVICE_SECRET="$(client_secret "$SERVICE_CLIENT_ID")"

if [[ "$CREATE_AZUL_SERVICE_SECRET" == "true" ]]; then
  kubectl create namespace "$AZUL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$AZUL_NAMESPACE" create secret generic azul-service-account \
    --from-literal=client_id="$SERVICE_CLIENT_ID" \
    --from-literal=client_secret="$SERVICE_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

cat <<EOF
Configured Keycloak realm: $REALM

Azul Helm OIDC values:
security:
  oidc:
    enabled: true
    authority_url: "$KEYCLOAK_URL/realms/$REALM"
    client_id: "azul-web"
    scopes: "openid profile offline_access roles azul"

Users created/updated:
  $BASIC_USER / $BASIC_PASSWORD
  $OPENSEARCH_ADMIN_USER / $OPENSEARCH_ADMIN_PASSWORD

Service account client:
  client_id: $SERVICE_CLIENT_ID
  client_secret: $SERVICE_SECRET
EOF
