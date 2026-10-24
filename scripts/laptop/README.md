# Laptop helpers

`ollama-setup.sh` adds shell shortcuts on your laptop for the DevBox Ollama API at `http://ollama.internal`, which sits behind Traefik basic auth. For IDEs and other clients, see [docs/remote-ide-setup.md](../../docs/remote-ide-setup.md).

## Requirements

- The laptop is on the same tailnet as the server.
- `ollama.internal` resolves to the server's Tailscale IP, for example via `/etc/hosts`: `100.x.y.z  ollama.internal ai.internal`.
- `curl` and `jq` are installed.

## Usage

```bash
DEVBOX_OLLAMA_AUTH="$(ssh -p 5522 dev@<server> cat docker/.secrets/ollama-auth.txt)" \
  bash scripts/laptop/ollama-setup.sh
source ~/.zshrc        # or ~/.bashrc / ~/.profile, as reported by the script
```

Optional variables:

| Variable | Default |
|---|---|
| `DEVBOX_OLLAMA_URL` | `http://ollama.internal` (use `https://ollama.<domain>` in HTTPS mode) |
| `DEVBOX_OLLAMA_MODEL` | `llama3.2` (must be pulled on the server) |

The script:

- Stores the credential in `~/.config/devbox/ollama.curlrc` (mode 0600). curl reads it with `-K`, so the password never appears on a command line.
- Calls `/api/version` and warns if it doesn't return HTTP 200.
- Writes a managed block, delimited by `# >>> devbox-ollama` and `# <<< devbox-ollama <<<`, into the rc file of your login shell: `~/.zshrc`, `~/.bashrc` or `~/.profile`. Re-running the script replaces the block instead of appending another one.

## Commands

```bash
ask "What does set -euo pipefail do?"     # one-shot answer
askcode "Bash loop over lines of a file"  # coding-assistant prompt
chat "Explain cgroups"                    # streamed answer
ollamals                                  # models on the server
```

To use another model, change `DEVBOX_OLLAMA_MODEL` in your shell or re-run the script with it set.

## After rotating the credential

When `~/docker/rotate-ollama-auth.sh` has run on the server, run the usage command again to store the new credential.

## Removal

Delete the `devbox-ollama` block from your rc file, then run `rm ~/.config/devbox/ollama.curlrc`.
