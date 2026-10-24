# Ollama tuning

The `ollama` container takes its limits and runtime settings from `~/docker/ollama-openwebui/.env`. setup.sh creates that file once and afterwards only manages `COMPOSE_FILE`, `DOMAIN` and the initial `OLLAMA_CPUS`, so your edits survive re-runs.

## Settings

| Variable | Default | Effect |
|---|---|---|
| `OLLAMA_MEM_LIMIT` | `8g` | Container memory limit. Swap is set to the same value, so the container gets no swap. It must hold the largest model you load plus its context cache. |
| `OLLAMA_CPUS` | nproc capped at 4 (set by setup) | CPU quota for the container |
| `OLLAMA_KEEP_ALIVE` | Ollama's | How long a model stays loaded after the last request: `30m`, `-1` (forever), or `0` (unload immediately) |
| `OLLAMA_NUM_PARALLEL` | Ollama's | Concurrent requests per loaded model. Each slot adds its own context cache. |
| `OLLAMA_MAX_LOADED_MODELS` | Ollama's | How many models can be loaded at the same time |
| `OLLAMA_CONTEXT_LENGTH` | Ollama's | Default context window in tokens, used when the client doesn't set `num_ctx`. Larger values use more memory. |

An empty or missing value means Ollama's built-in default, which can change between Ollama releases. See `services/ollama-openwebui/.env.example` for the syntax.

## Sizing OLLAMA_MEM_LIMIT

1. Find the largest model you use: `docker exec ollama ollama list`. The SIZE column shows the size of the weights.
2. Set the limit to that size plus room for the context cache. About 1-2 GB covers the default context with one request at a time. Long contexts and `OLLAMA_NUM_PARALLEL` > 1 need more. If `OLLAMA_MAX_LOADED_MODELS` is above 1, add up the models you expect to be loaded at once.
3. Leave headroom for the rest of the host: Open WebUI (capped at 1 GB), Traefik, Exegol and the OS.

Rough examples for 4-bit quantized models: a 7-8B model is about 5 GB, so the default `8g` is enough. A 32B model is about 20 GB, so set `24g` or more, on a host with at least 32 GB of RAM.

To check the limit against real usage:

```bash
docker exec ollama ollama ps            # loaded models, their size, CPU/GPU split
docker stats --no-stream ollama         # usage against the limit
docker inspect -f '{{.State.OOMKilled}}' ollama
```

If the limit is too low, Ollama either refuses to load the model with a memory error or the container is OOM-killed. Raise the limit, shorten the context, or use a smaller or more heavily quantized model.

## Applying changes

```bash
cd ~/docker/ollama-openwebui
$EDITOR .env                  # e.g. OLLAMA_MEM_LIMIT=16g, OLLAMA_KEEP_ALIVE=30m
docker compose up -d          # recreates ollama with the new values
docker exec ollama env | grep '^OLLAMA_'
```

`docker compose restart` doesn't re-read `.env`. Use `up -d`, or `~/docker/start-all.sh`.

## GPU

Only NVIDIA GPUs are supported. The host needs the NVIDIA driver (`nvidia-smi` works) and the NVIDIA Container Toolkit registered with Docker:

```bash
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
docker info --format '{{json .Runtimes}}' | grep nvidia
```

Then enable the overlay, which gives the container all GPUs:

```bash
sudo DEVBOX_GPU=nvidia ./setup.sh     # adds docker-compose.gpu.yml to COMPOSE_FILE; remembered in config.env
~/docker/start-all.sh
```

To check that the GPU is used, run `docker exec ollama ollama ps`. The PROCESSOR column should read `100% GPU`. A CPU/GPU split means the model doesn't fully fit in VRAM: use a smaller model or quantization, or a shorter context. `docker logs ollama 2>&1 | grep -iE 'cuda|gpu'` shows what Ollama detected at startup. To turn the GPU off again: `sudo DEVBOX_GPU=none ./setup.sh`, then `start-all.sh`.

`OLLAMA_MEM_LIMIT` limits system RAM only. With full GPU offload, the model's weights live in VRAM, but Ollama still needs RAM while it loads them.

## Practical defaults

- **CPU-only hosts:** keep `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_NUM_PARALLEL=1`, and prefer 4-bit quantized models of 8B or smaller.
- **Avoid reload delays:** set `OLLAMA_KEEP_ALIVE=30m` or longer if you use the same model all day and the memory isn't needed elsewhere.
- **Agents and IDE tools:** these often need a long context. Set `OLLAMA_CONTEXT_LENGTH` explicitly and raise `OLLAMA_MEM_LIMIT` to match.
