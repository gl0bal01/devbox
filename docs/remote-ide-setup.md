# Using the server's models from your laptop

IDEs, CLIs and scripts on another tailnet device can use the server's Ollama models through Traefik. Ollama's port 11434 is not published on the host, so guides that point at `<tailscale-ip>:11434` won't work.

| Endpoint | Auth | API | Fits |
|---|---|---|---|
| `http://ollama.internal` (or `https://ollama.<domain>`) | HTTP basic auth, user `ollama` | Native Ollama API (`/api/tags`, `/api/generate`, `/api/chat`, ...) | Clients with an Ollama provider that can send a custom `Authorization` header |
| `http://ai.internal/api` (or `https://ai.<domain>/api`) | Open WebUI API key, sent as a Bearer token | OpenAI-compatible (`/api/models`, `/api/chat/completions`) | Clients with an "OpenAI-compatible" provider |

## Prerequisites

- The laptop is on the same tailnet (`tailscale status`).
- The names resolve to the server's Tailscale IP. Add to `/etc/hosts`: `100.x.y.z  ai.internal ollama.internal traefik.internal exegol.internal`. In HTTPS mode, use DNS instead ([https-setup.md](https-setup.md#4-name-resolution-on-clients)).
- At least one model is pulled on the server: `docker exec ollama ollama pull qwen3`, the `opull` alias, or the Open WebUI model settings. Pick sizes that fit `OLLAMA_MEM_LIMIT` ([ollama-optimization.md](ollama-optimization.md)).

## Ollama API with basic auth

Fetch the credential and test it:

```bash
CRED=$(ssh -p 5522 dev@<server> cat docker/.secrets/ollama-auth.txt)   # ollama:<password>
curl -u "$CRED" http://ollama.internal/api/tags
curl -u "$CRED" http://ollama.internal/api/generate -d '{"model":"qwen3","prompt":"Say hi","stream":false}'
```

For shell shortcuts (`ask`, `askcode`, `chat`, `ollamals`), see [scripts/laptop/README.md](../scripts/laptop/README.md).

To configure an IDE or other client:

- **Base URL:** `http://ollama.internal`, with no `:11434` and no `/api` suffix, unless the client asks for the full API path.
- **Auth:** the client must support one of these:
  - A custom request header: `Authorization: Basic <base64 of ollama:password>`. Generate the value with `printf '%s' "$CRED" | base64 | tr -d '\n'`.
  - Credentials in the URL: `http://ollama:<password>@ollama.internal`. Many HTTP libraries turn URL credentials into basic auth, but not every client passes them through.

Header and provider settings differ between clients and versions, so check your client's documentation for "custom headers" or "request options". If it supports neither form, use one of the alternatives below.

After `~/docker/rotate-ollama-auth.sh`, fetch the credential again and update every client.

## Alternative: Open WebUI API key

Open WebUI requires a signed-in user or an API key, and does not use the Ollama basic-auth credential.

1. In Open WebUI, go to **Settings → Account → API keys** and create a key. If the section is missing, an admin first has to enable API keys or grant users that permission in the Admin Panel settings. Where these options live depends on the Open WebUI version.
2. Test it:

   ```bash
   curl -H "Authorization: Bearer $OPENWEBUI_KEY" http://ai.internal/api/models
   curl -H "Authorization: Bearer $OPENWEBUI_KEY" -H 'Content-Type: application/json' \
     http://ai.internal/api/chat/completions \
     -d '{"model":"qwen3","messages":[{"role":"user","content":"Say hi"}]}'
   ```
3. In an OpenAI-compatible client, set the base URL to `http://ai.internal/api`, the API key to the Open WebUI key, and the model to a name from `/api/models`.

Open WebUI also proxies the native Ollama API under `/ollama/`, for example `http://ai.internal/ollama/api/tags`. That path accepts the same Bearer key, which helps with Ollama clients that support an API key but not basic auth. Verify it against your Open WebUI version before relying on it.

## Alternative: SSH tunnel to the container

For tools that can't send credentials at all, such as the official `ollama` CLI with `OLLAMA_HOST`, forward a local port to the Ollama container over SSH. This skips basic auth, which is acceptable because SSH access is already root-equivalent.

```bash
OLLAMA_IP=$(ssh -p 5522 dev@<server> "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ollama")
ssh -p 5522 -N -L 11434:"$OLLAMA_IP":11434 dev@<server> &
OLLAMA_HOST=http://127.0.0.1:11434 ollama list
```

The container IP can change when the container is recreated, for example after an update. Look it up again if the tunnel stops working.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Connection timeout | The laptop isn't on the tailnet, the hosts entry is wrong, or an ACL blocks the server | `tailscale ping <server>`, then check `/etc/hosts` |
| `401 Unauthorized` | Missing or stale credential | Fetch `ollama-auth.txt` again. Check the base64 value has no trailing newline. |
| `403 Forbidden` | The source address isn't a Tailscale address | Connect directly through Tailscale, not through a subnet router or proxy |
| `404` on `/v1/...` or `/api/...` | Wrong base URL for the provider type | Ollama provider: `http://ollama.internal`. OpenAI-compatible provider: `http://ai.internal/api`. |
| Model list empty | No models pulled | `docker exec ollama ollama pull <model>` |
| Very slow first answer | The model is loading, or running on CPU | Keep it loaded longer, or use a smaller model ([ollama-optimization.md](ollama-optimization.md)) |
