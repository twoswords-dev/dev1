#!/usr/bin/env bash
set -euo pipefail

INFRA_NAMESPACE="${INFRA_NAMESPACE:-azul-infra}"
APP_NAMESPACE="${APP_NAMESPACE:-azul-app}"
INFRA_CA_SECRET="${INFRA_CA_SECRET:-azul-infra-ca}"
CONFIGMAP="${CONFIGMAP:-azul-ca-bundle}"
KEY="${KEY:-ca.crt}"
OUT_FILE="${OUT_FILE:-}"

command -v kubectl >/dev/null
command -v base64 >/dev/null

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

kubectl -n "$INFRA_NAMESPACE" get secret "$INFRA_CA_SECRET" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMPDIR/infra-ca.crt"

if kubectl -n "$APP_NAMESPACE" get configmap "$CONFIGMAP" >/dev/null 2>&1; then
  kubectl -n "$APP_NAMESPACE" get configmap "$CONFIGMAP" -o jsonpath="{.data.${KEY//./\\.}}" > "$TMPDIR/current.crt" || true
else
  : > "$TMPDIR/current.crt"
fi

cat "$TMPDIR/current.crt" > "$TMPDIR/new.crt"
if ! grep -Fq "$(openssl x509 -in "$TMPDIR/infra-ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" <(
  awk 'BEGIN{c=0}/BEGIN CERT/{c++; f="'$TMPDIR'/cert" c ".crt"} {if(f) print > f} /END CERT/{f=""}' "$TMPDIR/current.crt" 2>/dev/null || true
  for cert in "$TMPDIR"/cert*.crt; do [ -e "$cert" ] && openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; done
); then
  {
    printf '\n# %s/%s ca.crt added by update-azul-app-ca-bundle.sh\n' "$INFRA_NAMESPACE" "$INFRA_CA_SECRET"
    cat "$TMPDIR/infra-ca.crt"
    printf '\n'
  } >> "$TMPDIR/new.crt"
fi

kubectl -n "$APP_NAMESPACE" create configmap "$CONFIGMAP" \
  --from-file="$KEY=$TMPDIR/new.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "$OUT_FILE" ]]; then
  cp "$TMPDIR/new.crt" "$OUT_FILE"
fi

echo "Updated $APP_NAMESPACE/$CONFIGMAP key $KEY with $INFRA_NAMESPACE/$INFRA_CA_SECRET CA"
