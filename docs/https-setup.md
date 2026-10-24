# HTTPS with Let's Encrypt (OVH DNS-01)

HTTPS mode is optional. It serves `https://ai.<domain>` and `https://ollama.<domain>` with Let's Encrypt certificates. Traefik obtains them through the DNS-01 challenge against an OVH-hosted DNS zone, so the server never has to be reachable from the internet. Port 443 is bound to the Tailscale IP, just like port 80. The `.internal` HTTP names keep working, and the Traefik dashboard stays at `http://traefik.internal`.

What changes when `ENABLE_HTTPS=true`:

- `~/docker/traefik/traefik.yml` is rendered from `services/traefik/traefik.https.yml.template`. It adds the `websecure` entrypoint with HSTS, and the `letsencrypt` resolver, which uses OVH DNS-01 and stores certificates in `acme.json` on the named volume `traefik_letsencrypt`.
- `COMPOSE_FILE` in each service `.env` gains `docker-compose.https.yml`. That adds port 443 on the Tailscale IP and the TLS routers for `ai.<domain>` and `ollama.<domain>`. The Ollama router keeps its basic auth.
- The OVH credentials are copied to `~/.config/devbox/ovh.env` and rendered to `~/docker/traefik/ovh.env`, both mode 0600.

Traefik requests one certificate per host name.

## 1. Create an OVH API token

The domain's DNS zone must be hosted at OVH. Create a token at <https://api.ovh.com/createToken/> (use the matching regional portal if you're outside the EU) with these rights:

```
GET    /domain/zone/*
POST   /domain/zone/*
PUT    /domain/zone/*
DELETE /domain/zone/*
```

OVH shows the application key, application secret and consumer key only once.

## 2. Write ovh.env

```
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=...
OVH_APPLICATION_SECRET=...
OVH_CONSUMER_KEY=...
```

Valid endpoints include `ovh-eu`, `ovh-ca` and `ovh-us`. setup.sh looks for the file in this order:

1. The path in `DEVBOX_OVH_ENV`.
2. The operator's `~/.config/devbox/ovh.env`, for example `/home/dev/.config/devbox/ovh.env`.
3. `~/.config/devbox/ovh.env` of the user running setup.sh. Under sudo that's root's, which is useful on a first install, before the operator user exists.

Keep the file at mode 0600. setup.sh parses it without sourcing it.

## 3. Run setup

```bash
sudo ENABLE_HTTPS=true DEVBOX_DOMAIN=example.org DEVBOX_EMAIL=you@example.org ./setup.sh
~/docker/start-all.sh
```

Preflight fails, before any host change, if the domain, the email or any of the four OVH keys is missing. These settings are saved in `~/.config/devbox/config.env`, so later runs don't need the variables again.

## 4. Name resolution on clients

Clients must resolve the names to the server's Tailscale IP (`tailscale ip -4` on the server). Choose one of:

- **Public DNS:** add a record `*.example.org` (or `ai` and `ollama`) of type `A`, pointing to the Tailscale IP. Every tailnet device then resolves the names with no extra setup. Off the tailnet the IP is unreachable, but the record does reveal the Tailscale address.
- **Tailscale split DNS:** point the domain at a resolver you control.
- **Hosts file:** add `100.x.y.z  ai.example.org ollama.example.org` to `/etc/hosts` on each client.

## 5. Verify

```bash
docker logs traefik 2>&1 | grep -iE 'acme|certificate|error'    # look for error lines
curl -sv -o /dev/null https://ai.example.org 2>&1 | grep -E 'subject:|issuer:'
```

The issuer should be Let's Encrypt. The first certificate usually takes a minute or two, because Traefik waits for the TXT record to propagate. Renewal is automatic. The `traefik_letsencrypt` volume survives setup re-runs and is included in backups, so restoring onto a new server doesn't request new certificates.

### Upgrading from an older install

Older installs kept certificates in `~/docker/traefik/letsencrypt/acme.json`, on the host. They are not migrated to the volume, so after upgrading, Traefik requests new certificates on first start. Once `https://ai.<domain>` serves a valid certificate, delete the old directory: `rm -r ~/docker/traefik/letsencrypt`.

## Switching back to HTTP

```bash
sudo ENABLE_HTTPS=false ./setup.sh
~/docker/start-all.sh
```

This restores the HTTP `traefik.yml`, removes `~/docker/traefik/ovh.env` and the HTTPS overlay, and keeps the `traefik_letsencrypt` volume and `~/.config/devbox/ovh.env`.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Browser shows Traefik's default self-signed certificate | `docker logs traefik 2>&1 \| grep -i acme` | Read the ACME error and use the rows below |
| ACME error `403` / `This call has not been granted` | The token rights | Create a token with all four methods on `/domain/zone/*` and update `~/.config/devbox/ovh.env`. Then run `sudo ./setup.sh` and `~/docker/start-all.sh`. |
| ACME error `Invalid signature` / `Invalid credential` | Wrong key or endpoint | Fix `OVH_ENDPOINT` or the keys, then re-run as above |
| Timeout waiting for propagation / `NXDOMAIN` | `dig +short NS example.org` must list OVH name servers | The zone isn't served by OVH; delegate it or use another domain |
| `too many certificates` (rate limit) | Whether the `traefik_letsencrypt` volume was deleted or recreated | Wait for the Let's Encrypt limit to reset. Don't remove the volume. |
| Name resolves but the connection times out | The client isn't on the tailnet, or the record points to a public IP | The record must point to the Tailscale IP |
| `docker compose` errors with `DOMAIN unset` | `grep DOMAIN ~/docker/ollama-openwebui/.env` | Re-run setup with `DEVBOX_DOMAIN` |

Never bind 443 to `0.0.0.0`. `security-check.sh` fails it, and it bypasses UFW ([security.md](security.md#network-exposure)).
