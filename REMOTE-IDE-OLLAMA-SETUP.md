# Using Remote Ollama Models with Local IDE (Zed / Google Antigravity)

## The Challenge

Ollama is running on the remote server at `127.0.0.1:11434` (localhost only). To use it with a local IDE, you need to bridge the connection.

---

## Option 1: SSH Tunnel (Recommended)

Forward your remote Ollama to your local machine:

```bash
# Run this locally - keeps Ollama accessible at localhost:11434
ssh -L 11434:127.0.0.1:11434 user@your-remote -N

# Or with your SSH config host
ssh -L 11434:127.0.0.1:11434 my-server -N

# Run in background
ssh -L 11434:127.0.0.1:11434 my-server -N -f
```

Then configure your local IDE:

### Zed Configuration

Edit `~/.config/zed/settings.json`:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://localhost:11434"
    }
  },
  "agent": {
    "default_model": {
      "provider": "ollama",
      "model": "your-model-name"
    }
  }
}
```

Additional model options:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://localhost:11434",
      "available_models": [
        {
          "name": "qwen3:latest",
          "display_name": "Qwen 3",
          "supports_tools": true,
          "supports_thinking": true
        },
        {
          "name": "devstral:latest",
          "display_name": "Devstral",
          "supports_tools": true
        }
      ]
    }
  }
}
```

### Google Antigravity Configuration

1. Open Settings (Ctrl+,)
2. Navigate to: **Settings > Models > Add Custom**
3. Enter endpoint: `http://localhost:11434`
4. Select your model from the dropdown

---

## Option 2: Expose Ollama via Tailscale

Modify Ollama to bind to your Tailscale interface:

```yaml
# ollama-openwebui/docker-compose.yml
services:
  ollama:
    ports:
      - "100.x.x.x:11434:11434"  # Replace with your Tailscale IP
```

Then in your local IDE, point to:
```
http://your-tailscale-hostname:11434
```

This keeps it private to your Tailscale network.

---

## Recommended Models for IDE Use

Based on community feedback (as of 2025):

| Model | Best For | Notes |
|-------|----------|-------|
| **qwen3** | General coding, agentic tasks | Good tool support |
| **devstral** | Code completion | Mistral's coding model |
| **codellama** | Code completion | Older but stable |
| **deepseek-coder-v2** | Code generation | Good performance |

---

## Agentic Mode Limitations

Local models don't perform as well for agentic tasks (file creation, multi-step operations) compared to cloud models like Claude or GPT-4. For best results:

- Use `qwen3` or `devstral` which have better tool support
- Set `"supports_tools": true` in Zed config
- Consider using cloud models for complex agentic tasks, local for completions

---

## Quick Test Commands

```bash
# Test Ollama is accessible via tunnel
curl http://localhost:11434/api/tags

# List available models
curl http://localhost:11434/api/tags | jq '.models[].name'

# Test a model
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3:latest",
  "prompt": "Hello, world!",
  "stream": false
}'
```

---

## Troubleshooting

### Tunnel disconnects
Use autossh for persistent tunnels:
```bash
autossh -M 0 -L 11434:127.0.0.1:11434 my-server -N
```

### Zed doesn't detect models
1. Ensure tunnel is active
2. Restart Zed
3. Check: Agent Panel > Settings > LLM Providers

### Slow responses
Local models on CPU are slow. Ensure Ollama is using GPU:
```bash
# On remote
docker logs ollama 2>&1 | grep -i gpu
```

---

## References

- [Zed LLM Providers Documentation](https://zed.dev/docs/ai/llm-providers)
- [Ollama - Zed Integration](https://docs.ollama.com/integrations/zed)
- [Google Antigravity Local Models](https://www.linkedin.com/posts/georgehaber_1-how-to-use-a-local-model-with-google-antigravity-activity-7408977528565952512-tbSF)

---

*Last updated: 2025-01-11*
