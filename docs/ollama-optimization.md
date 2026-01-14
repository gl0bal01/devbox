# Ollama and Open WebUI Optimization Guide

Configure Ollama and Open WebUI for optimal performance based on your server hardware and use case.

## Table of Contents

- [Overview](#overview)
- [Environment Variables](#environment-variables)
- [Port Binding Configuration](#port-binding-configuration)
- [Server Profiles](#server-profiles)
- [Resource Calculation](#resource-calculation)
- [Applying Configuration Changes](#applying-configuration-changes)
- [Performance Monitoring](#performance-monitoring)
- [Model Selection](#model-selection)

## Overview

Ollama performance depends on three factors:

1. **Hardware resources**: CPU cores, RAM, and GPU availability
2. **Configuration tuning**: Environment variables that control memory and threading
3. **Model selection**: Choosing models appropriate for your hardware

The default configuration works for most setups, but tuning these settings can improve response times and stability.

## Environment Variables

### Ollama Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `127.0.0.1:11434` | Network interface and port to bind |
| `OLLAMA_NUM_PARALLEL` | Auto | Maximum concurrent requests |
| `OLLAMA_MAX_LOADED_MODELS` | Auto | Models kept in memory simultaneously |
| `OLLAMA_KEEP_ALIVE` | `5m` | Time to keep model loaded after last request |
| `OLLAMA_NUM_THREADS` | Auto | CPU threads for inference |
| `OLLAMA_FLASH_ATTENTION` | `0` | Enable Flash Attention optimization |

### Detailed Variable Explanations

#### OLLAMA_HOST

Controls which network interface Ollama listens on.

```bash
OLLAMA_HOST=0.0.0.0:11434    # Listen on all interfaces
OLLAMA_HOST=127.0.0.1:11434  # Listen only on localhost (default)
```

**When to change**: Set to `0.0.0.0:11434` when you need direct network access to Ollama from other containers or external services without going through the reverse proxy.

#### OLLAMA_NUM_PARALLEL

Maximum number of requests Ollama processes simultaneously.

```bash
OLLAMA_NUM_PARALLEL=2    # Process 2 requests at once
OLLAMA_NUM_PARALLEL=4    # Process 4 requests at once
```

**How to calculate**:
- Each parallel request uses additional memory
- Formula: `available_ram / (model_size * 1.5)`
- Example: 24GB RAM with 8GB model = `24 / (8 * 1.5)` = 2 parallel requests

**When to increase**: Multiple users accessing Open WebUI simultaneously.

**When to decrease**: Memory errors or slow responses under load.

#### OLLAMA_MAX_LOADED_MODELS

Number of models kept in memory at once.

```bash
OLLAMA_MAX_LOADED_MODELS=1    # One model at a time
OLLAMA_MAX_LOADED_MODELS=2    # Two models loaded simultaneously
```

**How to calculate**:
- Formula: `available_ram / average_model_size`
- Example: 24GB RAM with 8GB models = 3 models maximum (but leave headroom)

**When to increase**: Frequently switching between multiple models.

**When to decrease**: Running large models or experiencing out-of-memory errors.

#### OLLAMA_KEEP_ALIVE

Duration to keep a model loaded in memory after the last request.

```bash
OLLAMA_KEEP_ALIVE=5m     # Unload after 5 minutes idle (default)
OLLAMA_KEEP_ALIVE=24h    # Keep loaded for 24 hours
OLLAMA_KEEP_ALIVE=0      # Unload immediately after each request
OLLAMA_KEEP_ALIVE=-1     # Never unload (keep forever)
```

**When to increase**:
- Frequent usage patterns with gaps between requests
- Fast response times are critical
- Server has sufficient RAM

**When to decrease**:
- Memory is limited
- Multiple models need to be available
- Infrequent usage patterns

#### OLLAMA_NUM_THREADS

CPU threads allocated for model inference.

```bash
OLLAMA_NUM_THREADS=8     # Use 8 CPU threads
OLLAMA_NUM_THREADS=4     # Use 4 CPU threads
```

**How to calculate**:
- Leave 1-2 cores for system and other services
- Formula: `total_cores - 2`
- Example: 8 core server = 6-7 threads for Ollama

**When to increase**: Running on CPU-only server with many cores.

**When to decrease**: Other services need CPU resources.

#### OLLAMA_FLASH_ATTENTION

Enables Flash Attention for faster inference on supported hardware.

```bash
OLLAMA_FLASH_ATTENTION=1    # Enable Flash Attention
OLLAMA_FLASH_ATTENTION=0    # Disable (default)
```

**When to enable**:
- Server has a supported GPU (NVIDIA with Compute Capability 7.0+)
- Running models that support Flash Attention
- Processing long context windows

**When to disable**:
- CPU-only inference
- Older GPU hardware
- Experiencing instability

## Port Binding Configuration

The `ports` section in docker-compose.yml controls network access to Ollama.

### Option 1: Localhost Only (Default)

```yaml
ports:
  - "127.0.0.1:11434:11434"
```

**Behavior**: Ollama accessible only from the server itself.

**Use cases**:
- Claude Code running on the same server via SSH
- Open WebUI accessing Ollama through Docker network
- Maximum security (no external access)

**Access method**: SSH tunnel from your local machine.

```bash
# On your local machine
ssh -L 11434:127.0.0.1:11434 dev@server -p 5522 -N

# Then access via http://localhost:11434
```

### Option 2: Tailscale Only

```yaml
ports:
  - "${TS_IP}:11434:11434"
```

**Prerequisites**: Set `TS_IP` in the `.env` file.

```bash
# In ~/docker/ollama-openwebui/.env
TS_IP=100.x.x.x
```

**Behavior**: Ollama accessible only from Tailscale network.

**Use cases**:
- Remote IDE integration (VS Code, Zed, Continue)
- Direct API access from Tailscale-connected devices
- Multi-user access from trusted devices

**Access method**: Direct connection via Tailscale IP.

```bash
# From any Tailscale-connected device
curl http://100.x.x.x:11434/api/tags
```

### Option 3: Both Localhost and Tailscale

```yaml
ports:
  - "127.0.0.1:11434:11434"
  - "${TS_IP}:11434:11434"
```

**Use cases**:
- Claude Code on server (localhost) plus remote IDE access (Tailscale)
- Flexibility for different access patterns

### Security Comparison

| Configuration | Network Exposure | Security Level |
|---------------|------------------|----------------|
| Localhost only | None | Highest |
| Tailscale only | Tailscale mesh | High |
| Both | Tailscale mesh | High |
| 0.0.0.0 (not recommended) | All interfaces | Low |

## Server Profiles

### Small Server (4GB RAM, 2 vCPU)

Suitable for: Light testing, small models only.

```yaml
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=1
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KEEP_ALIVE=5m
  - OLLAMA_NUM_THREADS=1
```

```yaml
mem_limit: 3g
memswap_limit: 4g
cpus: 1.5
```

**Recommended models**: `llama3.2:1b`, `qwen2.5:0.5b`, `phi3:mini`

### Medium Server (8GB RAM, 4 vCPU)

Suitable for: Individual development, moderate usage.

```yaml
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=1
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KEEP_ALIVE=1h
  - OLLAMA_NUM_THREADS=3
```

```yaml
mem_limit: 6g
memswap_limit: 8g
cpus: 3
```

**Recommended models**: `llama3.2:3b`, `codellama:7b`, `mistral:7b`

### Large Server (16GB RAM, 8 vCPU)

Suitable for: Regular development, multiple users.

```yaml
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=2
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KEEP_ALIVE=4h
  - OLLAMA_NUM_THREADS=6
```

```yaml
mem_limit: 12g
memswap_limit: 16g
cpus: 6
```

**Recommended models**: `llama3.1:8b`, `codellama:13b`, `deepseek-coder:6.7b`

### KVM8 Profile (32GB RAM, 8 vCPU)

Suitable for: Heavy usage, larger models, multiple concurrent users.

```yaml
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=2
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KEEP_ALIVE=24h
  - OLLAMA_NUM_THREADS=8
  - OLLAMA_FLASH_ATTENTION=1
```

```yaml
mem_limit: 24g
memswap_limit: 28g
cpus: 7
```

**Recommended models**: `llama3.1:8b`, `mixtral:8x7b`, `deepseek-coder:33b`
**Working with**: `hf.co/mradermacher/Huihui-Qwen3-Coder-30B-A3B-Instruct-abliterated-i1-GGUF:Q4_K_M`

### GPU Server (Any RAM with NVIDIA GPU)

Suitable for: Fast inference, large models.

```yaml
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=4
  - OLLAMA_MAX_LOADED_MODELS=2
  - OLLAMA_KEEP_ALIVE=24h
  - OLLAMA_FLASH_ATTENTION=1
```

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

**Note**: GPU memory limits model size. A 24GB GPU can run most 70B quantized models.

## Resource Calculation

### Step 1: Determine Available Resources

```bash
# Check total RAM
free -h

# Check CPU cores
nproc

# Check for GPU
nvidia-smi  # If available
```

### Step 2: Calculate Ollama Allocation

Reserve resources for system and other containers:

| Component | RAM Reservation | CPU Reservation |
|-----------|-----------------|-----------------|
| System | 2GB | 1 core |
| Open WebUI | 2GB | 1 core |
| Traefik | 256MB | 0.25 core |
| Other containers | Varies | Varies |

**Formula for Ollama limits**:
```
ollama_ram = total_ram - 4GB (system + webui)
ollama_cpus = total_cores - 2
```

### Step 3: Calculate Thread Count

```
OLLAMA_NUM_THREADS = ollama_cpus - 1
```

Leave one CPU for Ollama's internal operations.

### Step 4: Calculate Parallel Requests

```
OLLAMA_NUM_PARALLEL = floor(ollama_ram / (model_size * 1.5))
```

Each parallel request needs approximately 1.5x the model size in memory.

### Example Calculation

Server: 32GB RAM, 8 vCPU, using 8GB model

1. Ollama RAM: `32GB - 4GB = 28GB` (set `mem_limit: 24g` with buffer)
2. Ollama CPUs: `8 - 2 = 6` (set `cpus: 7` allowing burst)
3. Thread count: `6 - 1 = 5` (set `OLLAMA_NUM_THREADS=6-8`)
4. Parallel requests: `24 / (8 * 1.5) = 2` (set `OLLAMA_NUM_PARALLEL=2`)

## Applying Configuration Changes

### Method 1: Edit docker-compose.yml Directly

1. Open the configuration file:
   ```bash
   nano ~/docker/ollama-openwebui/docker-compose.yml
   ```

2. Uncomment and modify the environment section:
   ```yaml
   services:
     ollama:
       image: ollama/ollama:latest
       container_name: ollama
       restart: unless-stopped
       environment:
         - OLLAMA_HOST=0.0.0.0:11434
         - OLLAMA_NUM_PARALLEL=2
         - OLLAMA_MAX_LOADED_MODELS=1
         - OLLAMA_KEEP_ALIVE=24h
         - OLLAMA_NUM_THREADS=8
         - OLLAMA_FLASH_ATTENTION=1
   ```

3. Modify resource limits if needed:
   ```yaml
       mem_limit: 24g
       memswap_limit: 28g
       cpus: 7
   ```

4. Apply changes:
   ```bash
   cd ~/docker/ollama-openwebui
   docker compose down
   docker compose up -d
   ```

### Method 2: Use Environment File

1. Add variables to the `.env` file:
   ```bash
   nano ~/docker/ollama-openwebui/.env
   ```

2. Add Ollama settings:
   ```bash
   # Ollama Configuration
   OLLAMA_NUM_PARALLEL=2
   OLLAMA_MAX_LOADED_MODELS=1
   OLLAMA_KEEP_ALIVE=24h
   OLLAMA_NUM_THREADS=8
   ```

3. Reference in docker-compose.yml:
   ```yaml
   environment:
     - OLLAMA_HOST=0.0.0.0:11434
     - OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL:-1}
     - OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS:-1}
     - OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE:-5m}
     - OLLAMA_NUM_THREADS=${OLLAMA_NUM_THREADS:-4}
   ```

4. Apply changes:
   ```bash
   cd ~/docker/ollama-openwebui
   docker compose down
   docker compose up -d
   ```

### Method 3: Change Port Binding

1. For Tailscale access, first get your Tailscale IP:
   ```bash
   tailscale ip -4
   ```

2. Add to `.env` file:
   ```bash
   TS_IP=100.x.x.x
   ```

3. Update ports in docker-compose.yml:
   ```yaml
   ports:
     - "${TS_IP}:11434:11434"
   ```

4. Apply changes:
   ```bash
   cd ~/docker/ollama-openwebui
   docker compose down
   docker compose up -d
   ```

### Verify Changes Applied

```bash
# Check container is running with new settings
docker inspect ollama | grep -A 20 "Env"

# Check port bindings
docker port ollama

# Test Ollama is responding
curl http://localhost:11434/api/tags
```

## Performance Monitoring

### Check Current Resource Usage

```bash
# Real-time container stats
docker stats ollama

# One-time snapshot
docker stats ollama --no-stream
```

### Monitor Memory Usage

```bash
# Check if model is loaded
docker exec ollama ollama ps

# Check model memory usage
docker exec ollama ollama ps --format json | jq
```

### Check Response Times

```bash
# Time a simple request
time curl -s http://localhost:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Hello",
  "stream": false
}' | jq -r '.response'
```

### Review Logs for Issues

```bash
# Check for errors
docker logs ollama 2>&1 | grep -i error

# Check for memory warnings
docker logs ollama 2>&1 | grep -i memory

# Full log review
docker logs ollama --tail 100
```

### Signs of Misconfiguration

| Symptom | Possible Cause | Solution |
|---------|----------------|----------|
| Very slow first response | Model loading from disk | Increase `OLLAMA_KEEP_ALIVE` |
| Out of memory errors | Model too large | Use smaller model or reduce `NUM_PARALLEL` |
| High CPU, slow responses | Too many threads | Reduce `OLLAMA_NUM_THREADS` |
| Requests timing out | Too many parallel requests | Reduce `OLLAMA_NUM_PARALLEL` |
| Model constantly reloading | Low `KEEP_ALIVE` value | Increase `OLLAMA_KEEP_ALIVE` |

## Model Selection

### Model Memory Requirements

| Model | Parameters | Memory Required | Recommended Server |
|-------|------------|-----------------|-------------------|
| llama3.2:1b | 1B | ~2GB | 4GB RAM |
| llama3.2:3b | 3B | ~4GB | 8GB RAM |
| llama3.1:8b | 8B | ~8GB | 16GB RAM |
| codellama:7b | 7B | ~6GB | 16GB RAM |
| codellama:13b | 13B | ~10GB | 24GB RAM |
| codellama:34b | 34B | ~20GB | 32GB RAM |
| mixtral:8x7b | 47B | ~26GB | 32GB RAM |
| llama3.1:70b | 70B | ~40GB | 64GB RAM or GPU |

### Choosing Quantization

Models come in different quantization levels that trade quality for memory:

| Quantization | Memory | Quality | Use Case |
|--------------|--------|---------|----------|
| Q4_0 | Lowest | Lower | Very limited RAM |
| Q4_K_M | Low | Good | Limited RAM |
| Q5_K_M | Medium | Better | Balanced |
| Q6_K | Higher | High | Quality focus |
| Q8_0 | High | Highest | Maximum quality |
| FP16 | Highest | Best | GPU with VRAM |

```bash
# Pull specific quantization
docker exec ollama ollama pull llama3.1:8b-q4_K_M
docker exec ollama ollama pull llama3.1:8b-q8_0
```

### Recommended Models by Use Case

**Code Completion**:
- Light: `codellama:7b`
- Heavy: `codellama:34b` or `deepseek-coder:33b`

**General Chat**:
- Light: `llama3.2:3b`
- Heavy: `llama3.1:8b` or `llama3.1:70b`

**Document Analysis**:
- Light: `mistral:7b`
- Heavy: `mixtral:8x7b`

---

*Last updated: 2026-01-14*
