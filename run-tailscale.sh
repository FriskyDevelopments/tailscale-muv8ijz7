#!/usr/bin/env bash
set -euo pipefail

export PORT="${PORT:-10000}"
ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-10.0.0.0/8}"
HOSTNAME="${RENDER_SERVICE_NAME:-render-subnet-router}"

python3 -u - <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path != "/health":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

port = int(os.environ["PORT"])
ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
HEALTH_PID=$!

cleanup() {
  kill "$HEALTH_PID" "${TS_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 0.2
if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
  echo "health server failed to start on port ${PORT}" >&2
  exit 1
fi

/render/tailscaled \
  --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --statedir=/var/lib/tailscale &
TS_PID=$!

until /render/tailscale up \
  --auth-key="${TAILSCALE_AUTHKEY}" \
  --hostname="${HOSTNAME}" \
  --advertise-routes="${ADVERTISE_ROUTES}"
do
  if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
    echo "health server exited" >&2
    exit 1
  fi
  sleep 0.1
done

echo "Tailscale is up at IP $(/render/tailscale ip)"

wait -n "$HEALTH_PID" "$TS_PID"
