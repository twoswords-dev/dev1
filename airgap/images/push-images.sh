#!/usr/bin/env bash
set -euo pipefail

# Push the images listed in images.txt to the private registry after loading them.
# The images are already tagged for registry-1.docker.io by values-airgap.yaml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_LIST="${IMAGE_LIST:-${SCRIPT_DIR}/images.txt}"
RUNTIME="${RUNTIME:-docker}"

while IFS= read -r image; do
  [[ -n "$image" && ! "$image" =~ ^# ]] || continue
  echo "Pushing $image"
  "$RUNTIME" push "$image"
done < "$IMAGE_LIST"
