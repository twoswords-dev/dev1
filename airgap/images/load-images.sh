#!/usr/bin/env bash
set -euo pipefail

# Load bundled image archives into the local container runtime on an airgapped node.
# For k3s/containerd you can use: RUNTIME='k3s ctr images import' ./load-images.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="${ARCHIVE_DIR:-${SCRIPT_DIR}/archives}"
RUNTIME="${RUNTIME:-docker load -i}"
shopt -s nullglob
for archive in "$ARCHIVE_DIR"/*.tar; do
  echo "Loading $archive"
  # shellcheck disable=SC2086
  $RUNTIME "$archive"
done
