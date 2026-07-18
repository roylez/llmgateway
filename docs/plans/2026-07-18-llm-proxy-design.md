# LLM Gateway — Proxy Design

## Overview

An Elixir LLM proxy inspired by LiteLLM. Provides a unified OpenAI-compatible API
that routes to multiple providers (OpenAI, Anthropic, OpenAI-compatible backends)
with API-style conversion, fallback chains, key-based access control, and model
metadata exposure from `llm_db`.

**Two modes of operation:**
- **Library mode** — call `Llmgateway.generate_text/3` directly from Elixir
- **HTTP server mode** — optional Bandit + Plug server on configurable port

**Key dependencies:** `req`, `llm_db`, `yaml_elixir`, `bandit` (optional), `igniter` (optional)

---

## 1. Config Format (YAML)

```yaml
server:
  port: 4000                    # Omit to skip HTTP server (library-only mode)

keys:
  - name: work-key
    value: $WORK_API_KEY         # $ prefix = resolved from env at boot
  - name: personal-key
    value: $PERSONAL_API_KEY

providers:
  - name: openrouter
    type: openrouter             # maps to llm_db provider :openrouter
    api_key: $OPENROUTER_API_KEY
  - name: openrouter-work
    type: openrouter
    api_key: $OPENROUTER_WORK_API_KEY
  - name: copilot
    type: github_copilot         # no api_key → web auth / oauth flow

models:
  - name: deepseek-v4-flash      # local alias — what clients use
    provider: openrouter         # references named provider above
    model: deepseek/deepseek-v4-flash  # upstream model ID
    keys: [work-key]             # optional — restrict to specific keys

  - name: deepseek-v4-flash-work
    provider: openrouter-work
    model: deepseek/deepseek-v4-flash
  - name: claude-sonnet
    provider: anthropic
    model: claude-sonnet-4-20250514

fallbacks:
  - deepseek-v4-flash: [claude-sonnet, gpt-4o-mini]

  # Generic fallback: if any model fails and has no specific fallback
  - "*": [claude-sonnet]
```

### Config loading rules

- `$VAR` values are resolved from OS environment at boot time
- Missing `$VAR` = startup error (hard fail)
- Provider `type` must match an `llm_db` provider ID (`:openai`, `:anthropic`, `:openrouter`, etc.)
- Models list the upstream `model` ID as known to the provider; capabilities come from `llm_db`
- Models with no `keys` field are accessible with any valid key
- Models with empty `keys: []` are inaccessible to all (explicit deny)
- Fallbacks are optional; `*` matches any model without its own fallback entry

---

## 2. Architecture / Component Tree

```
llmgateway/
├── config/
│   └── config.yaml
├── lib/
│   ├── llmgateway.ex               # Public API: generate_text/3, stream_text/3
│   ├── llmgateway/
│   │   ├── application.ex          # OTP Application
│   │   ├── config.ex               # YAML parser, $VAR resolver
│   │   ├── deployment.ex           # Deployment struct
│   │   ├── router.ex               # GenServer: model resolution, key auth, fallback lookup
│   │   ├── provider.ex             # Provider behavior + dispatch
│   │   ├── providers/
│   │   │   ├── openai.ex           # OpenAI / OpenAI-compatible backend adapter
│   │   │   └── anthropic.ex        # Anthropic adapter
│   │   ├── convert.ex              # Conversion dispatch
│   │   ├── convert/
│   │   │   ├── openai_to_anthropic.ex  # Request body: OpenAI → Anthropic
│   │   │   └── anthropic_to_openai.ex  # Response body: Anthropic → OpenAI
│   │   ├── fallback.ex             # Fallback chain executor
│   │   ├── key_auth.ex             # Key validation and model access check
│   │   ├── server.ex               # Plug router + Bandit HTTP server
│   │   ├── response.ex             # Response normalization helpers
│   │   └── telemetry.ex            # Telemetry events for observability
├── test/
└── mix.exs
```

### Data flow (HTTP server mode)

```
Client ──POST /v1/chat/completions──→ Server (Plug)
  │  headers: {Authorization: Bearer <key>}
  │  body: {model: "deepseek-v4-flash", messages: [...]}
  ▼
Router.resolve_key(key_value)  ──→ {:ok, "work-key"} or {:error, :invalid}
  │
Router.resolve_model("deepseek-v4-flash", key: "work-key")
  ──→ {:ok, deployment, fallbacks: [...]} or {:error, :forbidden/:not_found}
  │
Fallback.call(deployment, fallbacks, body, opts)
  │  tries each deployment in sequence
  ▼
Provider.call(deployment, converted_body, opts)
  │  Convert body to provider format
  │  Req.post to upstream
  │  Convert response back to OpenAI format
  ▼
Server ←─ {:ok, response} or {:error, error}
  │  Returns normalized JSON response
  ▼
Client (OpenAI-compatible format)
```

### Data flow (library mode)

```elixir
Llmgateway.generate_text("deepseek-v4-flash", "Hello", key: "work-key")
  # Same path: Router → Fallback → Provider
```

---

## 3. Router GenServer

### State

```elixir
defmodule Llmgateway.Router do
  use GenServer

  defstruct [
    :providers,     # %{"openrouter" => %ProviderConfig{type: :openrouter, api_key: "..."}}
    :models,        # %{"deepseek-v4-flash" => %ModelConfig{provider_name: "openrouter", upstream: "..."}}
    :keys,          # %{"work-key" => "sk-actual-value"}
    :fallbacks,     # [%{primary: "deepseek-v4-flash", fallbacks: ["claude-sonnet"]}, ...]
    :model_key_map  # %{"work-key" => MapSet.new(["deepseek-v4-flash"]), :any_key => MapSet.new([...])}
  ]
end
```

### Public API

```elixir
# Lifecycle
Router.start_link(config_path)   # Load YAML, resolve env vars, init state
Router.reload()                   # Hot-reload config (future)

# Resolution
Router.resolve_model(name, key: key_name)
  # → {:ok, %Deployment{}, fallbacks: [%Deployment{}, ...]}
  # → {:error, :not_found}       — model name not in config
  # → {:error, :forbidden}       — model exists but key can't access it
  #                                 (fallbacks may still be accessible)

Router.resolve_key(token)
  # → {:ok, key_name}
  # → {:error, :invalid_key}

Router.list_models(key: key_name)
  # → [%{name: "...", context: 200000, ...}, ...]
```

### Boot sequence

```
Application.start
  ↓
Config.load("config.yaml")
  ├── Parse YAML
  ├── Resolve $VAR → env values
  └── Validate provider types against llm_db
  ↓
Router.start_link(config)
  ├── Build %ProviderConfig{} map
  ├── Lookup llm_db provider metadata for each type
  ├── Build %ModelConfig{} map with llm_db enrichment
  ├── Build key → model access map
  └── Build fallback chains
  ↓
Maybe Server.start_link(port)
```

---

## 4. Key-Based Access Control

```elixir
defmodule Llmgateway.KeyAuth do
  def authenticate(token, state) do
    Enum.find_value(state.keys, {:error, :invalid_key}, fn {name, value} ->
      if Plug.Crypto.secure_compare(value, token), do: {:ok, name}
    end)
  end

  def allowed_models(key_name, state) do
    case state.model_key_map do
      %{^key_name => models} -> MapSet.union(models, state.model_key_map[:_any] || MapSet.new())
      %{} -> state.model_key_map[:_any] || MapSet.new()
    end
  end

  def accessible?(model_name, key_name, state) do
    model_name in allowed_models(key_name, state)
  end
end
```

Rules:
- Models with no `keys` field → added to `:_any` set (accessible to all keys)
- Models with `keys: [key-1]` → added only to that key's set
- If model has keys AND key is in `:_any` → accessible (union semantics)
- `secure_compare` used for constant-time token comparison

---

## 5. Conversion Layer

### Conversion dispatch

```elixir
defmodule Llmgateway.Convert do
  def to_provider(body, deployment) do
    case provider_family(deployment) do
      :openai_chat_compatible -> body            # passthrough
      :anthropic_messages     -> OpenAItoAnthropic.convert_request(body)
    end
  end

  def to_canonical(response_body, deployment) do
    case provider_family(deployment) do
      :openai_chat_compatible -> response_body   # passthrough
      :anthropic_messages     -> AnthropictoOpenAI.convert_response(response_body)
    end
  end

  defp provider_family(deployment) do
    # llm_db execution metadata tells us the canonical family
    case LLMDB.model({deployment.provider_type, deployment.upstream_model}) do
      {:ok, model} -> model.execution.text.family
      _ -> :openai_chat_compatible  # fallback for unknown
    end
  end
end
```

### OpenAI → Anthropic request mapper

```elixir
defmodule Llmgateway.Convert.OpenAIToAnthropic do
  @doc """
  Converts an OpenAI chat/completions request body to Anthropic messages format.

  Returns {converted_body, warnings} — warnings lists unsupported params that were dropped.
  """
  def convert_request(body) do
    {system, messages} = extract_system(body["messages"])
    {tools, tool_choice} = convert_tools(body["tools"], body["tool_choice"])
    {thinking, warnings} = convert_reasoning(body["reasoning_effort"])

    anthropic_body =
      %{
        model: body["model"],
        messages: messages,
        system: system,
        max_tokens: body["max_tokens"] || body["max_completion_tokens"]
      }
      |> maybe_put(:temperature, clamp(body["temperature"], 0, 1))
      |> maybe_put(:top_p, body["top_p"])
      |> maybe_put(:stop_sequences, body["stop"])
      |> maybe_put(:stream, body["stream"])
      |> maybe_put(:tools, tools)
      |> maybe_put(:tool_choice, tool_choice)
      |> maybe_put(:thinking, thinking)
      |> maybe_put_metadata(body["user"])

    {anthropic_body, warnings ++ unsupported_warnings(body)}
  end

  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_while(messages, &(&1["role"] == "system"))
    system_content = system_msgs |> Enum.map(& &1["content"]) |> Enum.join("\n")
    {system_content, rest}
  end

  defp convert_reasoning(nil), do: {nil, []}
  defp convert_reasoning("low"),    do: {%{type: "enabled", budget_tokens: 1024}, []}
  defp convert_reasoning("medium"), do: {%{type: "enabled", budget_tokens: 2048}, []}
  defp convert_reasoning("high"),   do: {%{type: "enabled", budget_tokens: 4096}, []}

  defp unsupported_warnings(body) do
    dropped = []
    dropped = if body["presence_penalty"],  do: [{:dropped, "presence_penalty"} | dropped], else: dropped
    dropped = if body["frequency_penalty"], do: [{:dropped, "frequency_penalty"} | dropped], else: dropped
    dropped = if body["logprobs"],          do: [{:dropped, "logprobs"} | dropped], else: dropped
    dropped
  end
end
```

### Anthropic → OpenAI response mapper

```elixir
defmodule Llmgateway.Convert.AnthropicToOpenAI do
  def convert_response(body) do
    choices = Enum.map(body["content"], &content_block_to_choice(&1, body["stop_reason"], body["role"]))

    usage = %{
      prompt_tokens: get_in(body, ["usage", "input_tokens"]),
      completion_tokens: get_in(body, ["usage", "output_tokens"]),
      total_tokens: get_in(body, ["usage", "input_tokens"]) + get_in(body, ["usage", "output_tokens"]),
      prompt_tokens_details: %{
        cached_tokens: get_in(body, ["usage", "cache_read_input_tokens"]) || 0,
        cache_creation_tokens: get_in(body, ["usage", "cache_creation_input_tokens"]) || 0
      }
    }

    %{
      id: body["id"],
      object: "chat.completion",
      created: now_unix(),
      model: body["model"],
      choices: choices,
      usage: usage
    }
  end
end
```

### Tool format mapping

```elixir
# OpenAI → Anthropic
defp convert_tool(%{type: "function", function: func}) do
  %{
    name: func["name"],
    description: func["description"] || "",
    input_schema: func["parameters"]
  }
end

# Anthropic → OpenAI
defp convert_tool_call(%{type: "tool_use", name: name, input: input, id: id}) do
  %{
    id: id,
    type: "function",
    function: %{
      name: name,
      arguments: Jason.encode!(input)
    }
  }
end
```

---

## 6. Fallback Chain

```elixir
defmodule Llmgateway.Fallback do
  def call_with_fallback(%Deployment{} = primary, fallbacks, body, opts) do
    case attempt(primary, body, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when is_list(fallbacks) and fallbacks != [] ->
        Logger.warning("Primary #{primary.name} failed: #{reason}. Trying fallbacks...")
        try_fallbacks(fallbacks, body, opts, primary.name, [reason])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_fallbacks([], _body, _opts, _original, errors) do
    {:error, %{error: "All deployments failed", fallback_errors: errors}}
  end

  defp try_fallbacks([fb | rest], body, opts, original, errors) do
    case Router.resolve_model(fb, key: opts[:key]) do
      {:ok, deployment, _fallbacks} ->
        case attempt(deployment, body, opts) do
          {:ok, response} ->
            {:ok, add_fallback_headers(response, original, fb)}

          {:error, reason} ->
            try_fallbacks(rest, body, opts, original, [{fb, reason} | errors])
        end

      {:error, _reason} ->
        try_fallbacks(rest, body, opts, original, [{fb, :inaccessible} | errors])
    end
  end
end
```

### Failure modes that trigger fallbacks

| Condition | Source |
|---|---|
| HTTP 429 (rate limited) | Req response |
| HTTP 5xx (server error) | Req response |
| HTTP timeout (connection / receive) | Req / Finch |
| Connection refused | Req / Finch |
| Provider-specific: `overloaded`, `rate_limit_error` | Response body parsing |

---

## 7. Provider Module

```elixir
defmodule Llmgateway.Provider do
  def call(deployment, body, opts) do
    # 1. Resolve llm_db provider metadata for base URL, auth type
    provider_meta = resolve_provider_meta!(deployment.provider_type)

    # 2. Convert body to provider format
    {converted_body, warnings} = Convert.to_provider(body, deployment)

    # 3. Build Req request
    req =
      Req.new(base_url: provider_meta.runtime.base_url)
      |> add_auth(deployment, provider_meta)
      |> Keyword.merge(opts[:req_opts] || [])

    # 4. Execute
    case Req.post(req, json: converted_body, receive_timeout: opts[:timeout] || 60_000) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        canonical = Convert.to_canonical(response_body, deployment)
        {:ok, attach_warnings(canonical, warnings)}

      {:ok, %{status: status, body: error_body}} ->
        {:error, classify_error(status, error_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_auth(req, %{api_key: key}, %{runtime: %{auth: %{type: "bearer"}}}) do
    Req.Request.put_header(req, "authorization", "Bearer #{key}")
  end

  defp add_auth(req, %{api_key: key}, %{runtime: %{auth: %{type: "x-api-key"}}}) do
    Req.Request.put_header(req, "x-api-key", key)
  end

  defp add_auth(req, _, _) do
    req  # no auth needed (e.g. local Ollama)
  end
end
```

### Provider auth types (from llm_db runtime metadata)

| llm_db auth type | Proxy handling |
|---|---|
| `bearer` | `Authorization: Bearer <key>` |
| `x-api-key` | `x-api-key: <key>` header |
| `basic` | `Authorization: Basic <base64>` |
| `oauth` | OAuth token exchange (future) |
| `none` | No auth header added |
| `aws_sigv4` | AWS Signature V4 (Bedrock — future) |

---

## 8. HTTP Server

```elixir
defmodule Llmgateway.Server do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :extract_key
  plug :match
  plug :dispatch

  # List models — includes context length from llm_db
  GET "/v1/models" do
    models = Router.list_models(key: conn.assigns[:key_name])
    send_json(conn, 200, %{object: "list", data: models})
  end

  # Get single model metadata
  GET "/v1/models/:model" do
    case Router.resolve_model(model, key: conn.assigns[:key_name]) do
      {:ok, deployment, _fallbacks} ->
        send_json(conn, 200, model_to_metadata(deployment))
      {:error, :not_found} -> send_json(conn, 404, %{error: "Model not found"})
      {:error, :forbidden} -> send_json(conn, 403, %{error: "Forbidden"})
    end
  end

  # Chat completions
  POST "/v1/chat/completions" do
    body = conn.body_params
    model_name = body["model"]

    case Router.resolve_model(model_name, key: conn.assigns[:key_name]) do
      {:ok, deployment, fallbacks} ->
        if body["stream"] do
          handle_stream(conn, deployment, fallbacks, body)
        else
          handle_non_stream(conn, deployment, fallbacks, body)
        end

      {:error, :not_found} -> send_json(conn, 404, %{error: "Model '#{model_name}' not found"})
      {:error, :forbidden} -> send_json(conn, 403, %{error: "Key lacks access to '#{model_name}'"})
    end
  end

  # Health check
  GET "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  defp extract_key(conn, _opts) do
    token = Plug.Conn.get_req_header(conn, "authorization")
            |> List.first()
            |> String.replace_prefix("Bearer ", "")

    case Router.resolve_key(token) do
      {:ok, key_name} -> assign(conn, :key_name, key_name)
      :error -> conn |> send_json(401, %{error: "Invalid API key"}) |> halt()
    end
  end
end

# Stream support via Bandit's chunked transfer
defp handle_stream(conn, deployment, fallbacks, body) do
  conn =
    conn
    |> send_chunked(200)
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-context-length", Integer.to_string(deployment.context))

  # Provider.stream returns an enumerable of SSE events
  Provider.stream(deployment, body, [])
  |> Enum.reduce_while(conn, fn event, conn ->
    case send_chunk(conn, "data: #{Jason.encode!(event)}\n\n") do
      {:ok, conn} -> {:cont, conn}
      {:error, _} -> {:halt, conn}
    end
  end)
  |> then(fn conn -> send_chunk(conn, "data: [DONE]\n\n") end)
end
```

### Response headers

| Header | Purpose |
|---|---|
| `x-context-length` | Model's max context from llm_db |
| `x-model-name` | Actual upstream model used (after fallback) |
| `x-key-name` | Key name used for auth (audit) |
| `x-fallback-depth` | Number of fallbacks attempted (0 if none) |

---

## 9. Cache & Context Length Exposure

### Response — cache tokens

The proxy normalizes all provider cache metrics into OpenAI's extended usage format:

```json
{
  "usage": {
    "prompt_tokens": 150,
    "completion_tokens": 50,
    "total_tokens": 200,
    "prompt_tokens_details": {
      "cached_tokens": 80,
      "cache_creation_tokens": 45
    }
  },
  "_llmgateway": {
    "deployment": "deepseek-v4-flash",
    "fallback_chain": ["deepseek-v4-flash", "claude-sonnet"]
  }
}
```

| Provider | `cached_tokens` source | `cache_creation_tokens` source |
|---|---|---|
| OpenAI | `usage.prompt_tokens_details.cached_tokens` | N/A |
| Anthropic | `usage.cache_read_input_tokens` | `usage.cache_creation_input_tokens` |
| OpenAI-compatible | Passthrough if present | N/A |

### GET /v1/models — context length

```json
GET /v1/models
{
  "object": "list",
  "data": [
    {
      "id": "deepseek-v4-flash",
      "object": "model",
      "created": 1710000000,
      "owned_by": "openrouter",
      "limits": {
        "context": 128000,
        "output": 16384
      }
    },
    {
      "id": "claude-sonnet",
      "object": "model",
      "created": 1710000000,
      "owned_by": "anthropic",
      "limits": {
        "context": 200000,
        "output": 8192
      }
    }
  ]
}
```

The `/v1/models` endpoint only returns models accessible with the current API key.

### Library mode — metadata access

```elixir
# Get context length programmatically
Llmgateway.get_model_metadata("deepseek-v4-flash")
# → %{context: 128000, output: 16384, provider: :openrouter, ...}

# Get response with full metadata
{:ok, response} = Llmgateway.generate_text("deepseek-v4-flash", "Hello")
response.usage.cached_tokens     # from prompt_tokens_details
response.deployment              # which deployment was used
```

---

## 10. Streaming

Streaming follows the OpenAI SSE format (`text/event-stream`) so clients just work.

```
data: {"choices":[{"delta":{"role":"assistant","content":""},"index":0}]}
data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}
data: {"choices":[{"delta":{"content":"! "},"index":0}]}
...
data: {"choices":[{"delta":{"content":"you?"},"index":0}],"usage":{"prompt_tokens":10,"completion_tokens":15}}
data: [DONE]
```

**Implementation:**
- Req + Finch handles SSE from upstream
- For Anthropic streaming: parse SSE events → convert each event to OpenAI SSE format → yield
- For OpenAI streaming: passthrough (already in format)
- Final event includes `usage` block with cache tokens

**Backpressure:** Bandit's chunked transfer handles backpressure naturally via TCP flow control.

---

## 11. Error Handling

```elixir
# Standardized error response (OpenAI-compatible)
{
  "error": {
    "message": "Provider anthropic returned 429: Rate limit exceeded",
    "type": "rate_limit_error",
    "code": 429,
    "param": null,
    "_llmgateway": {
      "deployment": "claude-sonnet",
      "fallback_chain": ["deepseek-v4-flash", "claude-sonnet"],
      "fallback_errors": [{"deepseek-v4-flash": "timeout"}]
    }
  }
}
```

### Error classification

| Upstream error | Proxy status | Proxy error type |
|---|---|---|
| 400 | 400 | `invalid_request_error` |
| 401 | 401 | `authentication_error` |
| 403 | 403 | `permission_error` |
| 404 | 404 | `not_found` |
| 429 | 429 | `rate_limit_error` |
| 5xx | 502 | `upstream_error` |
| Timeout | 504 | `timeout_error` |
| Invalid key | 401 | `authentication_error` |
| Forbidden model | 403 | `access_forbidden` |

### Warnings on unsupported params

When converting between providers, dropped parameters are:
1. Logged at `:warn` level
2. Included in response as `_llmgateway.warnings`

```json
{
  "choices": [...],
  "_llmgateway": {
    "warnings": [
      "presence_penalty dropped: not supported by anthropic",
      "frequency_penalty dropped: not supported by anthropic"
    ]
  }
}
```

---

## 12. Implementation Order (Phases)

### Phase 1 — Core library (no server)

- [ ] Project scaffold (`mix new llmgateway`)
- [ ] `Config` module — YAML parser + env var resolution
- [ ] `Router` GenServer — model resolution, key auth
- [ ] `Deployment` struct
- [ ] `Provider` module — basic Req call with auth from llm_db metadata
- [ ] OpenAI provider (passthrough, no conversion needed)
- [ ] `Llmgateway.generate_text/3` public API
- [ ] Tests for config parsing, routing, provider call

### Phase 2 — API conversion

- [ ] `Convert.OpenAIToAnthropic` — request body conversion
- [ ] `Convert.AnthropicToOpenAI` — response body conversion
- [ ] Anthropic provider adapter
- [ ] Tool call format conversion
- [ ] Streaming conversion
- [ ] Tests for full round-trip conversion

### Phase 3 — Fallback chain

- [ ] `Fallback` module
- [ ] Error classification
- [ ] Response metadata: x-fallback-depth, _llmgateway info
- [ ] Tests for fallback chain execution

### Phase 4 — HTTP server

- [ ] `Server` Plug — POST /v1/chat/completions
- [ ] GET /v1/models
- [ ] GET /v1/models/:model
- [ ] GET /health
- [ ] Streaming SSE output
- [ ] Key-based auth middleware
- [ ] Response headers: x-context-length, x-model-name

### Phase 5 — Polish

- [ ] Telemetry events
- [ ] Logging (stdout)
- [ ] Error response normalization
- [ ] Rate limiting (optional)
- [ ] README + docs

---

## 13. Future Considerations (not building now)

- **SQLite logging** — persist request/response/usage/history
- **Response caching** — cache identical requests to same model
- **OAuth token refresh** — for GitHub Copilot / oauth-based providers
- **AWS Bedrock** — requires AWS SigV4 signing (different transport)
- **Cost tracking** — llm_db provides cost metadata
- **Admin API** — hot-reload config without restart
- **Rate limiting** — per-key / per-model RPM tracking
- **Load balancing** — multiple deployments of same model with health checks
- **Provider-specific adapters as separate packages** (elixir provider ecosystem)

---

## Design Decisions Summary

| Decision | Choice | Rationale |
|---|---|---|
| Canonical format | OpenAI | Most agents/clients speak OpenAI format. Single conversion target. |
| Router type | GenServer | Future-proof for hot-reload, stateful cooldown tracking. |
| Config storage | GenServer state | Simple, testable. ETS if needed later. |
| Provider metadata | llm_db | No duplicated config. Auto-updates with version bumps. |
| API key notation | `$VAR_NAME` | Simple, familiar, works in Docker Compose. |
| Key auth | Per-attempt check | Fallbacks can succeed even if primary is forbidden. |
| Streaming | SSE passthrough | OpenAI format out of the box. |
| Unsupported params | Dropped + warn | Never silently ignore; client can adjust. |
| Cache tokens | Normalized into OpenAI format | Coding agents already read these fields. |
| DB | None (stdout logging) | Simpler v0. Add SQLite when logging/storage is needed. |