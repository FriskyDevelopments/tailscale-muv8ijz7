#!/usr/bin/env bash
# install-tailscale.sh – download and install the Tailscale static binary.
# Runs once at Docker build time. Set TAILSCALE_VERSION at build time via ARG.
set -euo pipefail

TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.96.4}"
ARCH="amd64"
TS_FILE="tailscale_${TAILSCALE_VERSION}_${ARCH}.tgz"
BASE_URL="https://pkgs.tailscale.com/stable"
INSTALL_DIR="/render"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "[install-tailscale] version=${TAILSCALE_VERSION} arch=${ARCH}"

# Download tarball and SHA256 checksum file
wget -q --show-progress=off \
  "${BASE_URL}/${TS_FILE}" \
  -O "${WORK_DIR}/${TS_FILE}"

wget -q --show-progress=off \
  "${BASE_URL}/${TS_FILE}.sha256" \
  -O "${WORK_DIR}/${TS_FILE}.sha256"

# Verify checksum before extracting.
# The .sha256 file contains only the hex digest (no filename), so we build
# a sha256sum-compatible line manually.
echo "[install-tailscale] verifying checksum..."
expected_hash="$(cat "${WORK_DIR}/${TS_FILE}.sha256" | tr -d '[:space:]')"
actual_hash="$(sha256sum "${WORK_DIR}/${TS_FILE}" | awk '{print $1}')"

if [[ "${expected_hash}" != "${actual_hash}" ]]; then
  echo "[install-tailscale] ERROR: checksum mismatch!"
  echo "  expected: ${expected_hash}"
  echo "  actual:   ${actual_hash}"
  exit 1
fi
echo "[install-tailscale] checksum OK"

echo "[install-tailscale] extracting..."
tar -xzf "${WORK_DIR}/${TS_FILE}" \
  --strip-components=1 \
  -C "${WORK_DIR}"

# Install binaries and supporting directories
mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
install -m 0755 "${WORK_DIR}/tailscale"  "${INSTALL_DIR}/tailscale"
install -m 0755 "${WORK_DIR}/tailscaled" "${INSTALL_DIR}/tailscaled"

echo "[install-tailscale] installed: $("${INSTALL_DIR}/tailscale" version)"
