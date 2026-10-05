#!/usr/bin/env bash
set -euo pipefail

TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.96.4}"
archive="tailscale_${TAILSCALE_VERSION}_amd64.tgz"
url="https://pkgs.tailscale.com/stable/${archive}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

wget -q -O "${tmp}/${archive}" "$url"
tar -C "$tmp" -xzf "${tmp}/${archive}" --strip-components=1
install -m 0755 "${tmp}/tailscale" "${tmp}/tailscaled" /render/
mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
