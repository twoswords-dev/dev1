#!/usr/bin/env bash
set -euo pipefail

# Pull source images on an internet-connected host, retag them for the private
# registry used by values-airgap.yaml, and save Docker archives.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_MAP="${IMAGE_MAP:-${SCRIPT_DIR}/images-map.tsv}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/archives}"
RUNTIME="${RUNTIME:-docker}"
mkdir -p "$OUT_DIR"

while IFS=$'\t' read -r source target; do
  [[ -n "${source:-}" && ! "$source" =~ ^# ]] || continue
  [[ -n "${target:-}" ]] || target="$source"
  archive="${OUT_DIR}/$(echo "$target" | sed 's#[/:@]#_#g').tar"
  echo "Pulling $source"
  "$RUNTIME" pull "$source"
  echo "Tagging $target"
  "$RUNTIME" tag "$source" "$target"
  echo "Saving $archive"
  "$RUNTIME" save -o "$archive" "$target"
done < "$IMAGE_MAP"
