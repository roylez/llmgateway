# LLM Gateway

An Elixir proxy for LLM providers. Accepts requests in OpenAI or Anthropic format, routes to any provider, handles API conversion automatically, and falls back across providers on failure.

## Features

- **Unified API** — clients talk OpenAI or Anthropic format; the proxy converts as needed
- **Multi-provider** — OpenAI, Anthropic, OpenRouter, GitHub Copilot, Ollama, and any provider listed on [llmdb.xyz](https://llmdb.xyz)
- **Same model, multiple credentials** — run the same provider type under different names with different API keys
- **Fallback chains** — automatic failover across providers on 5xx, timeout, or rate limit
- **Key-based access control** — virtual API keys with per-model access restrictions
- **Model metadata** — context length, output limits, and capabilities sourced from llmdb automatically
- **Cache token exposure** — Anthropic cache metrics normalized into OpenAI response format
- **GitHub Copilot** — fully automatic device code auth, no CLI tools needed
- **Streaming** — real SSE streaming with format conversion

## Quick Start

```bash
# Clone and install dependencies
git clone <repo-url> && cd llmgateway
mix deps.get

# Create your config
cp config.example.yaml config/config.yaml
# Edit config/config.yaml with your providers and API keys

# Run
mix run --no-halt
```

The proxy starts on the port defined in your config (default 4000).

## Configuration

See `config.example.yaml` for a fully annotated example. The config has four sections:

### Providers

Define connections to upstream LLM services. The `type` field maps to a provider on [llmdb.xyz](https://llmdb.xyz) — base URLs and auth are resolved automatically.

```yaml
providers:
  - name: openrouter
    type: openrouter
    api_key: $OPENROUTER_API_KEY

  - name: copilot
    type: github_copilot
```

Environment variables use `$VAR` syntax and are resolved at boot.

### Models

Each model maps a local name to an upstream provider model. `name` is optional — defaults to the `model` value.

```yaml
models:
  # Shorthand — clients request "deepseek/deepseek-chat"
  - provider: openrouter
    model: deepseek/deepseek-chat

  # Explicit name — clients request "gpt-4o"
  - name: gpt-4o
    provider: openai
    model: gpt-4o
    keys: [prod]          # restrict to specific keys
```

Same model name can appear multiple times with different providers and keys. The proxy picks the first deployment accessible by the current key:

```yaml
  - name: deepseek
    provider: openrouter-work
    model: deepseek/deepseek-chat
    keys: [work]

  - name: deepseek
    provider: openrouter
    model: deepseek/deepseek-chat
    keys: [personal]
```

Model metadata (context length, output limits) is sourced from llmdb — no manual config needed.

### Keys

Virtual API keys for authenticating clients. Models without a `keys` field are accessible to all keys.

```yaml
keys:
  - name: dev
    value: $LLMGATEWAY_DEV_KEY
  - name: prod
    value: $LLMGATEWAY_PROD_KEY
```

Omit the `keys` section entirely to allow unauthenticated access.

### Fallbacks

When a deployment fails with a retryable error, try the next model in the chain. Key access is checked per-attempt — a fallback can succeed even if the primary model is restricted.

```yaml
fallbacks:
  gpt-4o: [claude-sonnet, deepseek/deepseek-chat]
  "*": [gpt-4o-mini]              # catch-all
```

## API Endpoints

The proxy exposes two API styles. Use whichever your client expects.

### OpenAI Format

```bash
# Chat completion
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LLMGATEWAY_DEV_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v3",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Streaming
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LLMGATEWAY_DEV_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v3",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'

# List models
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LLMGATEWAY_DEV_KEY"
```

### Anthropic Format

```bash
# Chat completion
curl http://localhost:4000/v1/messages \
  -H "x-api-key: $LLMGATEWAY_DEV_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Streaming
curl http://localhost:4000/v1/messages \
  -H "x-api-key: $LLMGATEWAY_DEV_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet",
    "max_tokens": 1024,
    "stream": true,
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Response Headers

Every response includes:

| Header | Description |
|---|---|
| `x-context-length` | Model's max context window (from llmdb) |
| `x-model-name` | Upstream model ID actually used |

### Health Check

```bash
curl http://localhost:4000/health
```

## API Conversion

The proxy converts between API styles transparently:

| Client sends | Upstream provider | What happens |
|---|---|---|
| OpenAI format | OpenAI/OpenRouter | Pass through |
| OpenAI format | Anthropic | Convert request → Anthropic messages, convert response back |
| Anthropic format | Anthropic | Convert to canonical OpenAI internally, then pass through |
| Anthropic format | OpenAI/OpenRouter | Convert to canonical OpenAI, pass through |

Parameters that don't map between providers (e.g., `presence_penalty` for Anthropic) are dropped with a warning in the `_llmgateway.warnings` response field.

Key mappings:

| OpenAI | Anthropic |
|---|---|
| `messages[system]` | `system` (top-level) |
| `stop` | `stop_sequences` |
| `reasoning_effort` | `thinking.budget_tokens` |
| `tools[].function.parameters` | `tools[].input_schema` |
| `tool_choice: "required"` | `tool_choice: {type: "any"}` |
| `usage.prompt_tokens_details.cached_tokens` | `usage.cache_read_input_tokens` |

## GitHub Copilot

GitHub Copilot auth is fully automatic — no `gh` CLI or manual token setup needed.

```yaml
providers:
  - name: copilot
    type: github_copilot

models:
  - name: copilot-gpt4o
    provider: copilot
    model: gpt-4o
```

On first request, the proxy initiates a GitHub device code flow:

```
╔══════════════════════════════════════════════════╗
║  GitHub Copilot Authorization                    ║
║                                                  ║
║  Go to: https://github.com/login/device          ║
║  Enter code: WDJB-MJHT                           ║
╚══════════════════════════════════════════════════╝
```

Tokens are cached to disk and auto-refresh. The storage location is resolved in order:

1. `server.data_dir` in config YAML
2. `LLMGATEWAY_DATA_DIR` environment variable
3. `~/.config/llmgateway/` (default)

## Docker

### docker-compose (recommended)

```bash
# Create config directory and config file
mkdir -p config
cp config.example.yaml config/config.yaml
# Edit config/config.yaml with your providers and API keys

docker compose up -d
```

### docker run

```bash
docker build -t llmgateway .

docker run -p 4000:4000 \
  -v ./config:/config \
  --env-file .env \
  llmgateway
```

Create a `.env` file with your API keys (referenced by `$VAR` in config.yaml):

```
OPENROUTER_API_KEY=sk-or-...
ANTHROPIC_API_KEY=sk-ant-...
LLMGATEWAY_DEV_KEY=my-dev-key
```

### File permissions

The container runs as UID/GID 1000 by default. If your `config/` directory has different ownership, set `PUID`/`PGID` to match:

```bash
# docker-compose — set in .env or shell
PUID=$(id -u) PGID=$(id -g) docker compose up -d

# docker build
docker build --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) -t llmgateway .
```

The container uses `/config` for both configuration and persistent data. One mount holds everything:

```
config/
  config.yaml              # proxy configuration
  github_copilot/           # cached Copilot tokens (created automatically)
```

## Library Mode

Use directly in Elixir without the HTTP server — omit `server.port` from config:

```elixir
# In your application
{:ok, config} = Llmgateway.Config.load("config/config.yaml")
{:ok, _} = Llmgateway.Router.start_link(config)

# Generate text
{:ok, response} = Llmgateway.generate_text("deepseek-v3", %{
  "messages" => [%{"role" => "user", "content" => "Hello!"}]
}, key: "dev")

# Stream
{:ok, stream} = Llmgateway.stream_text("deepseek-v3", %{
  "messages" => [%{"role" => "user", "content" => "Hello!"}],
  "stream" => true
})

Enum.each(stream, fn
  :done -> :ok
  chunk -> IO.write(get_in(chunk, ["choices", Access.at(0), "delta", "content"]) || "")
end)

# List models
models = Llmgateway.list_models(key: "dev")
```

## Config Reload

Reload the config without restarting:

```elixir
Llmgateway.Router.reload("config/config.yaml")
```
