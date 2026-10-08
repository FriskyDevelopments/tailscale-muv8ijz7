# Run Tailscale on Render

![image](https://github.com/render-examples/tailscale/assets/168030/2513267e-6503-45c6-b596-3713160ae4ec)

[Tailscale](https://tailscale.com) is a zero-config VPN built on [WireGuard](https://www.wireguard.com/). This repo deploys a Tailscale **exit node** (or subnet router) as a background worker on Render. It wraps the Tailscale static binary with a resilient shell supervisor that:

- persists node state to a 1 GB disk so restarts reuse identity without re-authentication
- supports reusable auth keys or tagged OAuth clients (no single-use keys)
- retries `tailscale up` with exponential backoff (bounded, configurable)
- runs a periodic health check and self-heals on transient state drops
- handles `SIGTERM` gracefully so Render instance recycling doesn't corrupt state

---

## Deployment

### Prerequisites

- A Render account (Hobby plan or above)
- A Tailscale account

### One-Click Deploy (Blueprint)

> **Note:** Render preview environments require the Professional plan. On Hobby you get no PR previews for this service type.

<a href="https://render.com/deploy?repo=https://github.com/FriskyDevelopments/tailscale-muv8ijz7/tree/quality">
  <img src="https://render.com/images/deploy-to-render-button.svg" alt="Deploy to Render">
</a>

The blueprint creates a **background worker** named `tailscale-exit-node` with:
- Docker runtime, Starter plan, Oregon region
- 1 GB persistent disk at `/var/lib/tailscale`
- `TS_AUTHKEY` marked secret (you supply the value)

---

## Auth Options

Choose **one** of the two methods below. Switching later requires re-deploying with the new env vars set.

### Option A — Reusable Auth Key (simplest)

1. Go to [Tailscale Admin → Auth Keys](https://login.tailscale.com/admin/settings/authkeys).
2. Click **Generate auth key**.
3. Set:
   - **Reusable**: ✅ ON — critical; a single-use key breaks on every Render instance recycle
   - **Expiry**: set to 90 days or more (you'll rotate before it expires)
   - **Ephemeral**: leave OFF — you want the node to persist in your tailnet
   - **Pre-authorized**: ✅ ON — skips manual approval
4. Copy the key (`tskey-auth-...`).
5. In Render dashboard → service → **Environment** → set `TS_AUTHKEY` to the copied value.

### Option B — Tagged OAuth Client (recommended for automation)

OAuth clients never expire and support tags, which lets you use ACL `autoApprovers`.

1. Go to [Tailscale Admin → OAuth Clients](https://login.tailscale.com/admin/settings/oauth).
2. Click **Generate OAuth client**.
3. Grant scope: `devices:write`.
4. Copy the **client secret** (`tskey-client-...`).
5. In Render dashboard → service → **Environment**:
   - Set `TS_OAUTH_CLIENT_SECRET` to the secret value.
   - Set `TS_TAGS` to `tag:exit-node` (or whatever tag you use in your ACL).
   - Remove or clear `TS_AUTHKEY` if it exists.
6. Ensure the tag exists in your tailnet ACL (see ACL section below).

---

## Exit Node vs Subnet Router

| Mode | Env var | Effect |
|------|---------|--------|
| **Exit node** (default) | `ADVERTISE_EXIT_NODE=true` | All client traffic routes through Render |
| **Subnet router** | `ADVERTISE_EXIT_NODE=false` + `ADVERTISE_ROUTES=10.0.0.0/8` | Only Render private IPs are accessible |

The live service advertises exit node (`routes=[0.0.0.0/0 ::/0]`). To keep that behavior, leave `ADVERTISE_EXIT_NODE=true`.

### Approving the exit node / subnet routes

After the first successful deploy, you must approve routes in Tailscale Admin — **or** use `autoApprovers` in the ACL (recommended):

#### Manual approval
1. Go to [Tailscale Admin → Machines](https://login.tailscale.com/admin/machines).
2. Find `render-exit-node`.
3. Click **…** → **Edit route settings**.
4. Enable **Use as exit node** (or check the subnet routes you want).

#### autoApprovers in your tailnet ACL (no manual step needed)

Add this to your `tailnet-policy.hujson` at [Tailscale Admin → Access Controls](https://login.tailscale.com/admin/acls):

```json
{
  "autoApprovers": {
    // Approve exit node routes advertised by machines tagged tag:exit-node
    "exitNode": ["tag:exit-node"],
    // Or for subnet router routes:
    "routes": {
      "10.0.0.0/8": ["tag:exit-node"]
    }
  },
  "tagOwners": {
    "tag:exit-node": ["autogroup:admin"]
  }
}
```

This requires Option B (OAuth + tags). With Option A (auth key), approve routes manually.

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TS_AUTHKEY` | ✳ one of A/B | — | Reusable Tailscale auth key |
| `TS_OAUTH_CLIENT_SECRET` | ✳ one of A/B | — | OAuth client secret (alternative to auth key) |
| `TS_TAGS` | if using OAuth | — | Comma-separated tags, e.g. `tag:exit-node` |
| `TS_HOSTNAME` | no | `render-exit-node` | Tailscale machine name |
| `ADVERTISE_EXIT_NODE` | no | `true` | Advertise as exit node |
| `ADVERTISE_ROUTES` | no | `10.0.0.0/8` | Routes (only used when exit node is false) |
| `TAILSCALE_VERSION` | no | `1.96.4` | Tailscale binary version to install |
| `TS_UP_MAX_ATTEMPTS` | no | `5` | Max auth retry attempts before giving up |
| `TS_UP_TIMEOUT` | no | `60` | Seconds per `tailscale up` attempt |
| `TS_HEALTH_INTERVAL` | no | `30` | Seconds between health checks |
| `TS_HEALTH_FAIL_THRESHOLD` | no | `3` | Consecutive failures before hard exit |
| `TS_EXTRA_ARGS` | no | — | Extra flags appended to `tailscale up` |

---

## Rotating Auth Keys

When your auth key is approaching expiry:

1. Generate a new reusable key in Tailscale Admin.
2. In Render dashboard → service → **Environment** → update `TS_AUTHKEY`.
3. Trigger a manual deploy (or wait for the next commit-triggered deploy).

The persistent disk means the node keeps its identity; the new key is only used on the next cold start if the current session has expired.

---

## Pinning the Base Image

`Dockerfile` is pinned to `debian:bookworm-slim` by digest for reproducibility:

```
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
```

To update: run `docker pull debian:bookworm-slim` locally, note the new digest in the pull output, and update the `FROM` line.

---

## Troubleshooting

**Service exits daily at ~12:20 UTC with "failed to auth tailscale: context deadline exceeded"**

This is the exact bug this repo fixes. Root cause: the auth key was single-use or expired, so on each Render instance recycle the node had no stored state and couldn't silently re-authenticate. Fix: use a reusable key (Option A) or OAuth client (Option B).

**"profile not found" in logs**

The disk exists but node state was never written — likely because the first auth used a single-use key and the node never reached `Running` state before the key was consumed. After switching to a reusable key, the first successful auth will write state to disk and all subsequent restarts will be silent.

**"error initializing kube client"**

Benign. The official Tailscale Docker image runs `containerboot` which checks for Kubernetes env vars. Render is not Kubernetes; this warning is cosmetic and does not affect operation.
