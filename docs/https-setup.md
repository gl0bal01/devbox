# Adding Public HTTPS to DevBox

This guide walks you through enabling Let's Encrypt wildcard certificates via OVH DNS-01 challenge, so your services are accessible over HTTPS from the public internet.

**Default setup** (Tailscale-only, `ENABLE_HTTPS=false`) needs none of this — HTTP over Tailscale/WireGuard is already encrypted.

## Prerequisites

- A domain registered with or delegated to OVH DNS
- An OVH account with API access
- DevBox installed and working (Tailscale-only first)

---

## Step 1: Create OVH API Credentials

1. Go to [https://api.ovh.com/createToken/](https://api.ovh.com/createToken/)
2. Log in with your OVH account
3. Fill in the token form:
   - **Application name**: `traefik-letsencrypt`
   - **Application description**: `Traefik DNS-01 challenge for Let's Encrypt`
   - **Validity**: `Unlimited`
   - **Rights** (add each):
     ```
     GET    /domain/zone/*
     POST   /domain/zone/*
     DELETE /domain/zone/*
     ```
4. Click **Create keys**
5. Save the three values shown:
   - Application Key (`OVH_APPLICATION_KEY`)
   - Application Secret (`OVH_APPLICATION_SECRET`)
   - Consumer Key (`OVH_CONSUMER_KEY`)

---

## Step 2: Enable HTTPS in setup.sh (Fresh Install)

If you haven't run `setup.sh` yet, edit these variables before running:

```bash
# Your domain
DOMAIN="yourdomain.com"

# Enable HTTPS
ENABLE_HTTPS=true

# OVH credentials from Step 1
OVH_ENDPOINT="ovh-eu"          # or ovh-ca, ovh-us depending on your region
OVH_APPLICATION_KEY="your-app-key"
OVH_APPLICATION_SECRET="your-app-secret"
OVH_CONSUMER_KEY="your-consumer-key"
```

Then run:
```bash
./setup.sh
```

The script will:
- Configure Traefik with `websecure` entrypoint on port 443
- Create `traefik/letsencrypt/acme.json` (600 permissions)
- Write `traefik/.env` with OVH credentials (600 permissions)
- Configure Open WebUI with dual HTTP + HTTPS routers

---

## Step 3: Manual Steps for Existing Installs

If DevBox is already running, apply these changes manually.

### 3a. Create the OVH credentials file

```bash
cat > ~/docker/traefik/.env << 'EOF'
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=your-app-key
OVH_APPLICATION_SECRET=your-app-secret
OVH_CONSUMER_KEY=your-consumer-key
EOF
chmod 600 ~/docker/traefik/.env
```

### 3b. Create acme.json

```bash
mkdir -p ~/docker/traefik/letsencrypt
touch ~/docker/traefik/letsencrypt/acme.json
chmod 600 ~/docker/traefik/letsencrypt/acme.json
```

### 3c. Edit traefik/traefik.yml

Add the `websecure` entrypoint and `certificatesResolvers` block:

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:              # Add this
    address: ":443"       # Add this

# ... (existing providers, api, ping, log sections) ...

certificatesResolvers:    # Add this entire block
  letsencrypt:
    acme:
      email: your@email.com
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: ovh
        delayBeforeCheck: 0
```

### 3d. Edit traefik/docker-compose.yml

Add port 443, the letsencrypt volume, and env_file to the `traefik` service:

```yaml
traefik:
  # ... existing config ...
  env_file: .env          # Add this line
  ports:
    - "${TAILSCALE_IP}:80:80"
    - "${TAILSCALE_IP}:443:443"   # Add this line
  volumes:
    - ./traefik.yml:/etc/traefik/traefik.yml:ro
    - ./dynamic:/etc/traefik/dynamic:ro
    - ./logs:/var/log/traefik
    - ./letsencrypt:/letsencrypt   # Add this line
```

### 3e. Update Open WebUI labels

In `ollama-openwebui/docker-compose.yml`, replace the single router with dual routers:

```yaml
labels:
  - "traefik.enable=true"
  # HTTP: internal access
  - "traefik.http.routers.openwebui-http.rule=Host(`ai.internal`)"
  - "traefik.http.routers.openwebui-http.entrypoints=web"
  - "traefik.http.routers.openwebui-http.service=openwebui"
  # HTTPS: public access
  - "traefik.http.routers.openwebui-https.rule=Host(`ai.yourdomain.com`)"
  - "traefik.http.routers.openwebui-https.entrypoints=websecure"
  - "traefik.http.routers.openwebui-https.tls.certresolver=letsencrypt"
  - "traefik.http.routers.openwebui-https.service=openwebui"
  - "traefik.http.services.openwebui.loadbalancer.server.port=8080"
```

### 3f. Create a `.env` for docker compose variable expansion

The `${TAILSCALE_IP}` in the compose file is expanded by docker compose from the environment. Make sure it's set:

```bash
echo "TAILSCALE_IP=$(tailscale ip -4)" >> ~/docker/traefik/.env
```

Or export it before running docker compose:
```bash
export TAILSCALE_IP=$(tailscale ip -4)
```

### 3g. Apply changes

```bash
cd ~/docker/traefik
docker compose down
docker compose up -d
```

Then restart the OpenWebUI stack too:
```bash
cd ~/docker/ollama-openwebui
docker compose down
docker compose up -d
```

---

## Step 4: Verify Certificate Issuance

Watch Traefik logs for ACME activity:

```bash
docker logs traefik 2>&1 | grep -i "acme\|cert\|letsencrypt"
```

You should see lines like:
```
msg="Obtaining ACME certificate(s)" routerName=openwebui-https
msg="Certificate obtained successfully"
```

The first certificate typically takes 30-90 seconds (DNS propagation). If it fails, wait a minute and check logs again.

---

## Step 5: DNS Setup

Add a DNS record for your service at your DNS provider:

```
A    ai.yourdomain.com    →    your-server-public-IP
```

Or use a wildcard:
```
A    *.yourdomain.com     →    your-server-public-IP
```

---

## Step 6: Going Fully Public

By default, ports are bound to `${TAILSCALE_IP}` — reachable only via Tailscale. To expose publicly:

In `traefik/docker-compose.yml`, change:
```yaml
ports:
  - "${TAILSCALE_IP}:80:80"
  - "${TAILSCALE_IP}:443:443"
```
to:
```yaml
ports:
  - "0.0.0.0:80:80"
  - "0.0.0.0:443:443"
```

Then restart Traefik. You'll also want to add UFW rules if you open it to the public:
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

> **Security note**: Opening port 443 publicly exposes your services to the internet. Make sure Open WebUI has app-level authentication enabled and signup is disabled.

---

## Troubleshooting

### Certificate not issued after 5 minutes

**Check DNS propagation**:
```bash
dig TXT _acme-challenge.yourdomain.com
```
The TXT record should appear. If not, DNS propagation is still in progress (can take up to 10 minutes for some providers).

**Check Traefik logs for errors**:
```bash
docker logs traefik 2>&1 | grep -i error
```

Common errors:
- `401 Unauthorized` — OVH credentials incorrect, re-check Application/Consumer keys
- `NXDOMAIN` — domain doesn't exist or wrong `OVH_ENDPOINT` region
- `acme.json: permission denied` — file permissions wrong, run `chmod 600 traefik/letsencrypt/acme.json`

### acme.json permission error

```bash
chmod 600 ~/docker/traefik/letsencrypt/acme.json
docker compose restart traefik
```

### OVH API errors

Check your endpoint matches your OVH account region:
- Europe: `ovh-eu`
- Canada: `ovh-ca`
- United States: `ovh-us`

Verify the API token has the correct rights (GET/POST/DELETE on `/domain/zone/*`).

### Services still show HTTP after enabling HTTPS

1. Verify Traefik picked up the new config: `docker logs traefik | tail -20`
2. Check the router exists: visit `http://traefik.internal` → Routers tab
3. Verify `openwebui-https` router appears with `websecure` entrypoint

---

*See also: [Quick Reference](quick-reference.md) for TLS status commands*
