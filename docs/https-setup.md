# Tailscale-only HTTPS via OVH DNS-01

DevBox supports opt-in HTTPS using Let's Encrypt wildcard certificates issued via the OVH DNS-01 ACME challenge. The TLS listener is **bound to the Tailscale IP** — there is no public `0.0.0.0:443` exposure. The certificate is publicly issued (anyone can fetch the cert chain), but the listener is reachable only through Tailscale.

This document covers the OVH-side setup. The integrated install flow is documented in [docs/updating.md](updating.md) and the [Quick start](../README.md#quick-start) section of `README.md`.

## What HTTPS mode actually does

When `ENABLE_HTTPS=true`:

- `setup.sh` reads `~/.config/devbox/ovh.env` (must exist, mode 0600) — refuses to proceed if absent.
- Renders `services/traefik/traefik.https.yml.template` into `~/docker/traefik/traefik.yml`, replacing the HTTP-only static config.
- Creates `~/docker/traefik/letsencrypt/acme.json` (mode 0600).
- Renders `~/docker/traefik/.env` from `services/traefik/.env.template` with the four OVH credentials.
- Emits per-service `COMPOSE_FILE_<SVC>=docker-compose.yml:docker-compose.https.yml:docker-compose.lock.yml` into `~/.config/devbox/config.env` so helpers chain the HTTPS overlay automatically.
- The HTTPS overlay binds Traefik to `${TAILSCALE_IP}:443`. **No public bind.**

## Step 1 — Create OVH API credentials

1. Open <https://api.ovh.com/createToken/>.
2. Sign in.
3. Fill in:
   - **Application name**: `devbox-traefik-letsencrypt`
   - **Description**: `Traefik DNS-01 challenge for Let's Encrypt`
   - **Validity**: `Unlimited` (or set per your security policy)
   - **Rights**:
     ```
     GET    /domain/zone/*
     POST   /domain/zone/*
     DELETE /domain/zone/*
     ```
4. Click **Create keys**.
5. Save all three values — OVH only shows them once.

## Step 2 — Place credentials at the expected path

```bash
install -d -m 0700 ~/.config/devbox
cat > ~/.config/devbox/ovh.env <<EOF
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=your-application-key
OVH_APPLICATION_SECRET=your-application-secret
OVH_CONSUMER_KEY=your-consumer-key
EOF
chmod 600 ~/.config/devbox/ovh.env
```

Endpoint values: `ovh-eu` (Europe), `ovh-ca` (Canada), `ovh-us` (United States).

## Step 3 — Set HTTPS env vars and run setup

```bash
export ENABLE_HTTPS=true
export DEVBOX_DOMAIN=yourdomain.com
export DEVBOX_EMAIL=you@yourdomain.com   # for Let's Encrypt registration

# Optional preview without mutation:
./setup.sh --dry-run

# Apply:
sudo ./setup.sh
```

`setup.sh` halts with a clear error if `ENABLE_HTTPS=true` and `~/.config/devbox/ovh.env` is missing.

## Step 4 — DNS

Add an `A` (or `AAAA`) record for the FQDNs Traefik will serve. The cert is wildcard-eligible via DNS-01, so a single record per published host is fine:

```
A    ai.yourdomain.com           →  <Tailscale IP of devbox host>
A    ollama.yourdomain.com       →  <Tailscale IP of devbox host>
```

Your own devices still resolve via `/etc/hosts` to the Tailscale IP for the `.internal` names; the public `*.yourdomain.com` records exist so Traefik's DNS-01 challenge can answer the wildcard request and so cosign-validating clients see the published name.

## Step 5 — Verify cert issuance

After `start-all.sh`:

```bash
docker logs traefik 2>&1 | grep -iE 'acme|letsencrypt|certificate'
```

Expect:

```
Obtaining ACME certificate(s)
Certificate obtained successfully
```

First issuance typically takes 30–90 seconds (DNS propagation). Subsequent renewals (60-day cycle) are silent.

## Troubleshooting

**Certificate not issued after 5 minutes**

- `dig TXT _acme-challenge.yourdomain.com` — the TXT record must propagate.
- `docker logs traefik 2>&1 | grep -i error` — common errors:
  - `401 Unauthorized` — OVH credentials wrong; recheck App Key + Consumer Key.
  - `NXDOMAIN` — wrong endpoint region or zone not delegated to OVH.

**Permission errors on `acme.json`**

```bash
sudo chmod 600 ~/docker/traefik/letsencrypt/acme.json
docker compose -f ~/docker/traefik/docker-compose.yml -f ~/docker/traefik/docker-compose.https.yml restart traefik
```

**Routing the `https` URLs from your laptop**

Add the FQDNs to `/etc/hosts` on the laptop, mapped to the **Tailscale IP** (not the public IP):

```
100.X.Y.Z  ai.yourdomain.com  ollama.yourdomain.com
```

Or use Tailscale MagicDNS + a Tailscale-side split-DNS rule.

## Going fully public (NOT recommended)

If you want Traefik bound to `0.0.0.0:443` instead of the Tailscale IP, you must:

1. Edit `services/traefik/docker-compose.https.yml` to change the bind from `${TAILSCALE_IP}:443:443` to `0.0.0.0:443:443`.
2. Open the port in UFW: `sudo ufw allow 443/tcp`.
3. Disable Open WebUI signup, ensure ollama-auth credential is rotated, and run `~/docker/security-check.sh`.

This breaks the Tailscale-only assumption documented elsewhere (`README.md`, `ARCHITECTURE.md`). Prefer Tailscale ACLs over public exposure.

## See also

- [README.md — Quick start](../README.md#quick-start)
- [docs/updating.md — Install from a signed release tarball](updating.md#install-from-a-signed-release-tarball)
- [docs/security.md — Trust model](security.md)
- [ARCHITECTURE.md — HTTPS via Compose Override](../ARCHITECTURE.md)
