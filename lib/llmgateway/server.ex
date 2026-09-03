defmodule Llmgateway.Server do
  @moduledoc """
  HTTP server exposing an OpenAI- and LiteLLM-compatible API.

  Implemented endpoints:
  - `POST /v1/chat/completions` — chat completion (with optional streaming)
  - `POST /v1/messages` — Anthropic-format chat completion
  - `POST /v1/completions` — legacy text completions (proxied to chat)
  - `POST /v1/moderations` — content moderation (always benign)
  - `POST /v1/messages/count_tokens` — token count estimate
  - `GET /v1/models` — list available models
  - `GET /v1/models/:model` — get model metadata
  - `GET /v1/model/info` — LiteLLM model info
  - `GET /v1/model_group/info` — LiteLLM model group info
  - `GET /version` — Hermes/vLLM discovery endpoint
  - `GET /health` — liveness probe (200 whenever the HTTP server is up)
  - `GET /ready` — readiness probe (200 only when the runtime snapshot
    is valid and required children are running; 503 otherwise)

  Stub endpoints (501 for POST, empty list for GET, 404 for GET by ID):
  - embeddings, audio, images, rerank, files, batches,
    fine_tuning/jobs, assistants, threads, responses

  Unsupported native APIs return the standard 404 JSON error envelope:
  - Ollama (`/api/tags`, `/api/show`)
  - llama.cpp (`/props`)
  - LM Studio (`/api/v1/models`)
  """

  use Plug.Router

  require Logger

  alias Llmgateway.{ClientIdentity, Fallback, Responses, SSE, Serializer, Telemetry}

  plug(Plug.Logger, log: :debug)
  plug(:parse_body)
  plug(:authenticate)
  plug(Llmgateway.Plugs.StripV1Prefix)
  plug(:match)
  plug(:dispatch)

  # ── Health ─────────────────────────────────────────────────
  # Liveness: 200 whenever the HTTP server is up.
  get "/health" do
    Responses.send_json(conn, 200, %{"status" => "ok"})
  end

  # Readiness: 200 only when the runtime snapshot is valid and the
  # required children (router) are running.
  get "/ready" do
    if Llmgateway.Runtime.ready?() do
      Responses.send_json(conn, 200, %{"status" => "ready"})
    else
      Responses.send_json(conn, 503, Responses.error_body("Gateway not ready", "service_unavailable"))
    end
  end

  head "/api/hello" do
    Responses.send_json(conn, 200, %{})
  end

  # ── Hermes/vLLM discovery ──────────────────────────────────

  get "/version" do
    gateway_version = Application.spec(:llmgateway, :vsn) |> to_string()
    Responses.send_json(conn, 200, %{"version" => gateway_version})
  end

  # ── Models ─────────────────────────────────────────────────

  get "/models" do
    models = Llmgateway.list_models(key: conn.assigns[:key_name])
    data = Enum.map(models, &Serializer.serialize_model/1)
    Responses.send_json(conn, 200, %{"object" => "list", "data" => data})
  end

  get "/models/:model_id" do
    case Llmgateway.Router.resolve_model(model_id, key: conn.assigns[:key_name]) do
      {:ok, deployment, _fallbacks} ->
        Responses.send_json(conn, 200, Serializer.serialize_model(Llmgateway.Router.discovery_metadata(deployment)))

      {:error, :not_found} ->
        Responses.send_json(conn, 404, Responses.error_body("Model '#{model_id}' not found", "not_found"))

      {:error, :forbidden} ->
        Responses.send_json(conn, 403, Responses.error_body("Access denied to '#{model_id}'", "access_forbidden"))
    end
  end

  # ── LiteLLM discovery ─────────────────────────────────────

  get "/model/info" do
    models = Llmgateway.list_models(key: conn.assigns[:key_name])
    data = Enum.map(models, &Serializer.serialize_litellm_model_info/1)
    Responses.send_json(conn, 200, %{"data" => data})
  end

  get "/model_group/info" do
    models = Llmgateway.list_models(key: conn.assigns[:key_name])

    groups =
      models
      |> Enum.group_by(& &1.id)
      |> Enum.map(fn {name, entries} ->
        %{
          "model_group" => name,
          "models" =>
            Enum.map(entries, fn m -> %{"model_id" => m.id, "provider" => m.owned_by} end)
        }
      end)

    Responses.send_json(conn, 200, %{"data" => groups})
  end

  # ── Chat / Completions ────────────────────────────────────

  post "/chat/completions" do
    route_completion(conn, conn.body_params, conn.assigns[:key_name], ClientIdentity.app(conn))
  end

  post "/completions" do
    route_completion(conn, conn.body_params, conn.assigns[:key_name], ClientIdentity.app(conn))
  end

  post "/messages" do
    body = conn.body_params
    key_name = conn.assigns[:key_name]
    app = ClientIdentity.app(conn)

    rid = new_rid()

    Logger.info(
      "[anthropic-in] rid=#{rid} model=#{body["model"]} stream=#{body["stream"]} " <>
        "tools=#{length(body["tools"] || [])} key=#{key_name}"
    )

    canonical = Llmgateway.Convert.InboundAnthropic.to_canonical(body)

    if body["stream"] do
      Llmgateway.AnthropicRoutes.handle_stream(conn, body["model"], canonical, key_name, app, rid)
    else
      Llmgateway.AnthropicRoutes.handle_completion(conn, body["model"], canonical, key_name, app)
    end
  end

  # ── Moderations ───────────────────────────────────────────

  post "/moderations" do
    body = conn.body_params
    input = body["input"] || ""

    results =
      if is_list(input) do
        Enum.map(input, fn _ -> moderation_benign() end)
      else
        [moderation_benign()]
      end

    Responses.send_json(conn, 200, %{
      "id" => "modr-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
      "model" => body["model"] || "text-moderation-stable",
      "results" => results
    })
  end

  # ── Token counting ───────────────────────────────────────

  post "/messages/count_tokens" do
    body = conn.body_params
    model_name = body["model"]

    case Llmgateway.Router.resolve_model(model_name, key: conn.assigns[:key_name]) do
      {:ok, _deployment, _} ->
        text =
          [
            body["system"] || ""
            | Enum.map(body["messages"] || [], fn m -> m["content"] || "" end)
          ]
          |> Enum.join()

        Responses.send_json(conn, 200, %{
          "input_tokens" => div(String.length(text), 4),
          "output_tokens" => 0
        })

      {:error, :not_found} ->
        Responses.send_json(conn, 404, Responses.error_body("Model '#{model_name}' not found", "not_found"))

      {:error, _} ->
        Responses.send_json(conn, 403, Responses.error_body("Access denied to '#{model_name}'", "access_forbidden"))
    end
  end

  # ── Compatibility stubs (embeddings/files/assistants/etc) ─

  forward "/", to: Llmgateway.StubRoutes

  # ── Private: completion routing ────────────────────────────

  defp route_completion(conn, body, key_name, app) do
    model_name = body["model"]

    if body["stream"] do
      handle_stream(conn, model_name, body, key_name, app)
    else
      handle_completion(conn, model_name, body, key_name, app)
    end
  end

  defp handle_completion(conn, model_name, body, key_name, app) do
    case generate_text(model_name, body, key_name, app) do
      {:ok, response, deployment} ->
        conn
        |> Responses.put_context_header(deployment)
        |> Responses.send_json(200, response)

      {:error, %{type: :not_found}} ->
        Responses.send_json(conn, 404, Responses.error_body("Model '#{model_name}' not found", "not_found"))

      {:error, %{type: :forbidden}} ->
        Responses.send_json(conn, 403, Responses.error_body("Access denied to '#{model_name}'", "access_forbidden"))

      {:error, %{type: :rate_limit} = err} ->
        Responses.send_json(conn, 429, Responses.error_body(err[:message] || "Rate limited", "rate_limit_error"))

      {:error, %{type: :server_error} = err} ->
        Responses.send_json(conn, 502, Responses.error_body(err[:message] || "Upstream error", "upstream_error"))

      {:error, %{type: :all_failed, errors: errors}} ->
        details =
          Enum.map(errors, fn {name, e} ->
            %{"model" => name, "status" => e[:status], "reason" => e[:message] || inspect(e)}
          end)

        Responses.send_json(conn, 502, Responses.error_body("All providers failed", "upstream_error", details))

      {:error, %{type: :transport_error, reason: reason}} ->
        Responses.send_json(conn, 502, Responses.error_body("Transport error: #{inspect(reason)}", "upstream_error"))

      {:error, %{message: msg}} ->
        Responses.send_json(conn, 502, Responses.error_body(msg, "upstream_error"))

      {:error, err} ->
        Responses.send_json(conn, 500, Responses.error_body(format_error(err), "internal_error"))
    end
  end

  # ── Streaming ─────────────────────────────────────────────

  defp handle_stream(conn, model_name, body, key_name, app) do
    rid = new_rid()

    case Fallback.stream(model_name, body, key: key_name, app: app, rid: rid) do
      {:ok, stream, deployment} ->
        tel = Telemetry.request_start(deployment, app: app)

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-context-length", to_string(deployment.context || 0))
          |> put_resp_header("x-model-name", deployment.upstream_model)
          |> send_chunked(200)

        {conn, last_usage} =
          SSE.stream_loop(stream, conn, nil, deployment, rid, &reduce_openai/2, & &1)

        Telemetry.request_stop(tel, 200, last_usage)

        case chunk(conn, "data: [DONE]\n\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end

      {:error, %{type: :not_found}} ->
        Responses.send_json(conn, 404, Responses.error_body("Model '#{model_name}' not found", "not_found"))

      {:error, %{type: :forbidden}} ->
        Responses.send_json(conn, 403, Responses.error_body("Access denied to '#{model_name}'", "access_forbidden"))

      {:error, %{type: :all_failed, errors: errors}} ->
        details =
          Enum.map(errors, fn {name, e} ->
            %{"model" => name, "status" => e[:status], "reason" => e[:message] || inspect(e)}
          end)

        Responses.send_json(conn, 502, Responses.error_body("All providers failed", "upstream_error", details))

      {:error, err} ->
        Responses.send_json(conn, 502, Responses.error_body(inspect(err), "upstream_error"))
    end
  end

  defp reduce_openai(data, prev_usage) do
    this_usage = data["usage"] || prev_usage
    {:ok, ["data: #{Jason.encode!(data)}\n\n"], this_usage}
  end

  # ── Tracing helpers ───────────────────────────────────────

  # Compact, greppable request id shared across all logs for one request.
  defp new_rid do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp generate_text(model, body, key_name, app) do
    Llmgateway.generate_text(model, body, key: key_name, app: app)
  end

  # ── Plugs ─────────────────────────────────────────────────

  defp parse_body(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct] ->
        if String.starts_with?(ct, "application/json") do
          case Plug.Conn.read_body(conn, length: 10_000_000) do
            {:ok, raw, conn} ->
              case Jason.decode(raw) do
                {:ok, parsed} ->
                  %{conn | body_params: parsed}

                {:error, _} ->
                  conn |> Responses.send_json(400, Responses.error_body("Invalid JSON", "invalid_request")) |> halt()
              end

            {:more, _, conn} ->
              conn
              |> Responses.send_json(413, Responses.error_body("Request body too large", "invalid_request"))
              |> halt()

            {:error, _reason} ->
              conn
              |> Responses.send_json(400, Responses.error_body("Failed to read body", "invalid_request"))
              |> halt()
          end
        else
          conn
        end

      _ ->
        conn
    end
  end

  # Health probes bypass authentication; everything else requires a key
  # (or an open config) and a running router.
  defp authenticate(conn, _opts) do
    if conn.request_path in ["/health", "/ready"] do
      assign(conn, :key_name, nil)
    else
      case extract_bearer(conn) do
        nil ->
          if Process.whereis(Llmgateway.Router) do
            assign(conn, :key_name, nil)
          else
            conn
            |> Responses.send_json(503, Responses.error_body("Router not started", "service_unavailable"))
            |> halt()
          end

        token ->
          case Llmgateway.resolve_key(token) do
            {:ok, key_name} ->
              assign(conn, :key_name, key_name)

            {:error, :invalid_key} ->
              conn
              |> Responses.send_json(401, Responses.error_body("Invalid API key", "authentication_error"))
              |> halt()
          end
      end
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token

      _ ->
        case Plug.Conn.get_req_header(conn, "x-api-key") do
          [key] -> key
          _ -> nil
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────

  defp format_error(err), do: Responses.format_error(err)

  defp moderation_benign, do: %{"flagged" => false, "categories" => %{}, "category_scores" => %{}}
end
