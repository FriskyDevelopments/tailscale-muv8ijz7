#!/usr/bin/env bash
# run-tailscale.sh – start tailscaled and bring up the Tailscale connection.
#
# Supports two auth modes:
#   1. Reusable auth key:  set TS_AUTHKEY (preferred: reusable, not single-use)
#   2. Tagged OAuth client: set TS_OAUTH_CLIENT_SECRET + TS_TAGS
#
# Exit node mode: set ADVERTISE_EXIT_NODE=true (default: true, matches live service)
# Subnet router mode: set ADVERTISE_ROUTES=10.0.0.0/8 (only when exit node is false)
#
# Env vars consumed (also see README and render.yaml):
#   TS_AUTHKEY               – reusable Tailscale auth key (tskey-auth-...) [secret]
#   TS_OAUTH_CLIENT_SECRET   – OAuth client secret (tskey-client-...) [secret, alt to above]
#   TS_TAGS                  – comma-separated tags for OAuth, e.g. "tag:exit-node"
#   TS_HOSTNAME              – node hostname (default: render-exit-node)
#   ADVERTISE_EXIT_NODE      – true|false, advertise as exit node (default: true)
#   ADVERTISE_ROUTES         – CIDR routes when exit node is false (default: 10.0.0.0/8)
#   TS_EXTRA_ARGS            – extra flags appended to `tailscale up` verbatim
#   TS_UP_TIMEOUT            – seconds per `tailscale up` attempt (default: 60)
#   TS_UP_MAX_ATTEMPTS       – max auth attempts before giving up (default: 5)
#   TS_HEALTH_INTERVAL       – seconds between health checks (default: 30)
#   TS_HEALTH_FAIL_THRESHOLD – consecutive failures before hard exit (default: 3)

set -euo pipefail

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────
ts_log() {
  echo "[run-tailscale] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# Read stdin line-by-line and log each line with a timestamp prefix.
ts_log_lines() {
  while IFS= read -r _line; do
    ts_log "${_line}"
  done
}

die() {
  ts_log "FATAL: $*"
  exit 1
}

# ────────────────────────────────────────────────────────────
# Configuration (all defaults safe)
# ────────────────────────────────────────────────────────────
TS_HOSTNAME="${TS_HOSTNAME:-render-exit-node}"
ADVERTISE_EXIT_NODE="${ADVERTISE_EXIT_NODE:-true}"
ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-10.0.0.0/8}"
TS_UP_TIMEOUT="${TS_UP_TIMEOUT:-60}"
TS_UP_MAX_ATTEMPTS="${TS_UP_MAX_ATTEMPTS:-5}"
TS_HEALTH_INTERVAL="${TS_HEALTH_INTERVAL:-30}"
TS_HEALTH_FAIL_THRESHOLD="${TS_HEALTH_FAIL_THRESHOLD:-3}"
TS_STATEDIR="/var/lib/tailscale"
TS_BIN="/render/tailscale"
TSD_BIN="/render/tailscaled"
TSD_SOCK="/tmp/tailscaled.sock"
TSD_PID=""

# ────────────────────────────────────────────────────────────
# Health check helper (no external deps: grep only)
# Extracts BackendState from `tailscale status --json` output.
# Returns "Running", "NeedsLogin", "Stopped", etc., or "error" on failure.
# No python3 / jq required.
# ────────────────────────────────────────────────────────────
_backend_state() {
  local json
  json="$("${TS_BIN}" --socket="${TSD_SOCK}" status --json 2>/dev/null)" || { echo "error"; return; }
  # Extract value of "BackendState": "..." using only grep/sed (no python3/jq)
  # JSON field is always on its own line in tailscale's output.
  echo "${json}" \
    | grep -Eo '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | grep -Eo '"[^"]*"$' \
    | tr -d '"' \
    || echo "error"
}

# ────────────────────────────────────────────────────────────
# SIGTERM / SIGINT handler – graceful shutdown
# NOTE: Do NOT call `tailscale logout` here. Render sends SIGTERM on every
# instance recycle / deploy. Logging out would wipe the persisted node state
# and recreate the auth failure on every restart.  We only stop tailscaled
# cleanly so it can flush state to disk before the container exits.
# ────────────────────────────────────────────────────────────
_shutdown() {
  ts_log "Signal received – stopping tailscaled (state preserved on disk)..."
  if [[ -n "${TSD_PID}" ]] && kill -0 "${TSD_PID}" 2>/dev/null; then
    kill -TERM "${TSD_PID}" 2>/dev/null || true
    # Give tailscaled up to 15 s to flush WireGuard state to disk
    for _sd_i in $(seq 1 15); do
      kill -0 "${TSD_PID}" 2>/dev/null || break
      sleep 1
    done
    unset _sd_i
    kill -KILL "${TSD_PID}" 2>/dev/null || true
  fi
  ts_log "Shutdown complete."
  exit 0
}
trap _shutdown SIGTERM SIGINT

# ────────────────────────────────────────────────────────────
# Determine auth mode and build `tailscale up` flags
# ────────────────────────────────────────────────────────────
TS_UP_FLAGS=(
  "--socket=${TSD_SOCK}"
  "--hostname=${TS_HOSTNAME}"
  "--timeout=${TS_UP_TIMEOUT}s"
)

if [[ "${ADVERTISE_EXIT_NODE}" == "true" ]]; then
  TS_UP_FLAGS+=("--advertise-exit-node")
  ts_log "Mode: exit-node (routes=[0.0.0.0/0 ::/0])"
else
  TS_UP_FLAGS+=("--advertise-routes=${ADVERTISE_ROUTES}")
  ts_log "Mode: subnet-router (routes=${ADVERTISE_ROUTES})"
fi

# Auth key resolution:
#   1. TS_OAUTH_CLIENT_SECRET present → OAuth client flow (requires TS_TAGS)
#   2. TS_AUTHKEY present            → plain auth key
#   3. Neither present               → rely on persisted state on disk
AUTH_KEY_FLAG=""
if [[ -n "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
  [[ -n "${TS_TAGS:-}" ]] || die "TS_OAUTH_CLIENT_SECRET is set but TS_TAGS is empty. Set TS_TAGS to e.g. 'tag:exit-node'."
  AUTH_KEY_FLAG="--authkey=${TS_OAUTH_CLIENT_SECRET}?ephemeral=false&preauthorized=true"
  TS_UP_FLAGS+=("--advertise-tags=${TS_TAGS}")
  ts_log "Auth mode: OAuth client (tags=${TS_TAGS})"
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  AUTH_KEY_FLAG="--authkey=${TS_AUTHKEY}"
  ts_log "Auth mode: auth key"
else
  ts_log "Auth mode: no key set – will reuse persisted node state (disk must have valid state)"
fi

# Append extra args last (word-split intentional for user-supplied flags)
if [[ -n "${TS_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  TS_UP_FLAGS+=(${TS_EXTRA_ARGS})
fi

# ────────────────────────────────────────────────────────────
# Start tailscaled
# ────────────────────────────────────────────────────────────
mkdir -p "${TS_STATEDIR}" /var/run/tailscale /var/cache/tailscale

ts_log "Starting tailscaled (statedir=${TS_STATEDIR})..."
"${TSD_BIN}" \
  --tun=userspace-networking \
  --statedir="${TS_STATEDIR}" \
  --socket="${TSD_SOCK}" \
  --socks5-server=localhost:1055 \
  &
TSD_PID=$!
ts_log "tailscaled started (pid=${TSD_PID})"

# Wait for socket to appear (up to 30 s)
for _wait_i in $(seq 1 30); do
  [[ -S "${TSD_SOCK}" ]] && break
  sleep 1
done
unset _wait_i
[[ -S "${TSD_SOCK}" ]] || die "tailscaled socket did not appear after 30 s"
ts_log "tailscaled socket ready"

# ────────────────────────────────────────────────────────────
# tailscale up with bounded retries and exponential backoff
# ────────────────────────────────────────────────────────────
_tailscale_up() {
  local flags=("${TS_UP_FLAGS[@]}")
  # Only pass authkey on initial bring-up; health-check re-ups reuse disk state
  if [[ -n "${AUTH_KEY_FLAG}" ]]; then
    flags+=("${AUTH_KEY_FLAG}")
  fi
  "${TS_BIN}" up "${flags[@]}"
}

attempt=0
backoff=2
while true; do
  attempt=$(( attempt + 1 ))
  ts_log "tailscale up attempt ${attempt}/${TS_UP_MAX_ATTEMPTS}..."

  if _tailscale_up; then
    ts_log "tailscale up succeeded"
    break
  fi

  if (( attempt >= TS_UP_MAX_ATTEMPTS )); then
    ts_log "ERROR: tailscale up failed after ${TS_UP_MAX_ATTEMPTS} attempts – exiting so Render can restart"
    kill -TERM "${TSD_PID}" 2>/dev/null || true
    exit 1
  fi

  ts_log "tailscale up failed (attempt ${attempt}) – retrying in ${backoff}s..."
  sleep "${backoff}"
  backoff=$(( backoff * 2 > 120 ? 120 : backoff * 2 ))

  # Bail immediately if tailscaled died under us
  if ! kill -0 "${TSD_PID}" 2>/dev/null; then
    die "tailscaled (pid=${TSD_PID}) died unexpectedly during auth retry"
  fi
done

TS_IP="$("${TS_BIN}" --socket="${TSD_SOCK}" ip 2>/dev/null || echo '(unknown)')"
ts_log "Tailscale is up at IP ${TS_IP}"
export ALL_PROXY=socks5://localhost:1055/

# ────────────────────────────────────────────────────────────
# Health-check loop + tailscaled watchdog
# ────────────────────────────────────────────────────────────
consecutive_failures=0

while true; do
  # Watchdog: if tailscaled dies, exit non-zero so Render restarts the container
  if ! kill -0 "${TSD_PID}" 2>/dev/null; then
    die "tailscaled (pid=${TSD_PID}) exited unexpectedly – requesting Render restart"
  fi

  # Health check using grep only – no python3/jq dependency
  backend_state="$(_backend_state)"

  if [[ "${backend_state}" == "Running" ]]; then
    consecutive_failures=0
    ts_log "health OK (BackendState=Running)"
  else
    consecutive_failures=$(( consecutive_failures + 1 ))
    ts_log "WARN: health check failed (BackendState=${backend_state}, failure ${consecutive_failures}/${TS_HEALTH_FAIL_THRESHOLD})"

    if (( consecutive_failures < TS_HEALTH_FAIL_THRESHOLD )); then
      # Self-heal: re-run tailscale up WITHOUT authkey (reuse persisted state on disk)
      ts_log "Attempting self-heal (tailscale up without re-auth)..."
      "${TS_BIN}" up "${TS_UP_FLAGS[@]}" 2>&1 | ts_log_lines || true
    else
      die "Health check failed ${consecutive_failures} times consecutively (last state=${backend_state}) – requesting Render restart"
    fi
  fi

  sleep "${TS_HEALTH_INTERVAL}"
done
