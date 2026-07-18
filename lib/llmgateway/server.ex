defmodule Llmgateway.Server do
  @moduledoc """
  HTTP server exposing an OpenAI-compatible API.

  Endpoints:
  - `POST /v1/chat/completions` — chat completion (with optional streaming)
  - `GET /v1/models` — list available models
  - `GET /v1/models/:model` — get model metadata
  - `GET /health` — health check
  """

  use Plug.Router

  require Logger

  plug Plug.Logger, log: :debug
  plug :parse_body
  plug :authenticate
  plug :match
  plug :dispatch

  # ── Endpoints ─────────────────────────────────────────────

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  get "/v1/models" do
    models = Llmgateway.list_models(key: conn.assigns[:key_name])

    data =
      Enum.map(models, fn m ->
        %{
          "id" => m.id,
          "object" => "model",
          "created" => 0,
          "owned_by" => m.owned_by,
          "limits" => m.limits
        }
      end)

    send_json(conn, 200, %{"object" => "list", "data" => data})
  end

  get "/v1/models/:model_id" do
    case Llmgateway.Router.resolve_model(model_id, key: conn.assigns[:key_name]) do
      {:ok, deployment, _fallbacks} ->
        send_json(conn, 200, %{
          "id" => deployment.name,
          "object" => "model",
          "created" => 0,
          "owned_by" => Atom.to_string(deployment.provider_type),
          "limits" => %{
            "context" => deployment.context,
            "output" => deployment.output_limit
          }
        })

      {:error, :not_found} ->
        send_json(conn, 404, error_body("Model '#{model_id}' not found", "not_found"))

      {:error, :forbidden} ->
        send_json(conn, 403, error_body("Access denied to '#{model_id}'", "access_forbidden"))

      {:error, :forbidden, _fallbacks} ->
        send_json(conn, 403, error_body("Access denied to '#{model_id}'", "access_forbidden"))
    end
  end

  # Non-v1 paths for compatibility with clients that don't use /v1/
  post "/chat/completions" do
    body = conn.body_params
    model_name = body["model"]
    key_name = conn.assigns[:key_name]

    if body["stream"] do
      handle_stream(conn, model_name, body, key_name)
    else
      handle_completion(conn, model_name, body, key_name)
    end
  end

  post "/v1/chat/completions" do
    body = conn.body_params
    model_name = body["model"]
    key_name = conn.assigns[:key_name]


    if body["stream"] do
      handle_stream(conn, model_name, body, key_name)
    else
      handle_completion(conn, model_name, body, key_name)
    end
  end

  post "/messages" do
    body = conn.body_params
    model_name = body["model"]
    key_name = conn.assigns[:key_name]

    canonical_body = Llmgateway.Convert.InboundAnthropic.to_canonical(body)

    if body["stream"] do
      handle_anthropic_stream(conn, model_name, canonical_body, key_name)
    else
      handle_anthropic_completion(conn, model_name, canonical_body, key_name)
    end
  end

  post "/v1/messages" do
    body = conn.body_params
    model_name = body["model"]
    key_name = conn.assigns[:key_name]


    canonical_body = Llmgateway.Convert.InboundAnthropic.to_canonical(body)

    if body["stream"] do
      handle_anthropic_stream(conn, model_name, canonical_body, key_name)
    else
      handle_anthropic_completion(conn, model_name, canonical_body, key_name)
    end
  end

  match _ do
    Logger.warning("404 unmatched route: #{conn.method} #{conn.request_path}")
    send_json(conn, 404, error_body("Not found", "not_found"))
  end

  # ── Non-streaming completion ──────────────────────────────

  defp handle_completion(conn, model_name, body, key_name) do
    case Llmgateway.generate_text(model_name, body, key: key_name) do
      {:ok, response} ->
        conn
        |> put_context_header(model_name, key_name)
        |> send_json(200, response)

      {:error, %{type: :not_found}} ->
        send_json(conn, 404, error_body("Model '#{model_name}' not found", "not_found"))

      {:error, %{type: :forbidden}} ->
        send_json(conn, 403, error_body("Access denied to '#{model_name}'", "access_forbidden"))

      {:error, %{type: :rate_limit} = err} ->
        send_json(conn, 429, error_body(err[:message] || "Rate limited", "rate_limit_error"))

      {:error, %{type: :server_error} = err} ->
        send_json(conn, 502, error_body(err[:message] || "Upstream error", "upstream_error"))

      {:error, %{type: :all_failed, errors: errors}} ->
        messages = Enum.map(errors, fn {name, e} -> "#{name}: #{e[:message] || inspect(e)}" end)
        send_json(conn, 502, error_body(Enum.join(messages, "; "), "upstream_error"))

      {:error, %{type: :transport_error, reason: reason}} ->
        send_json(conn, 502, error_body("Transport error: #{inspect(reason)}", "upstream_error"))

      {:error, %{message: msg}} ->
        send_json(conn, 502, error_body(msg, "upstream_error"))

      {:error, err} ->
        send_json(conn, 500, error_body(format_error(err), "internal_error"))
    end
  end

  # ── Streaming ─────────────────────────────────────────────

  defp handle_stream(conn, model_name, body, key_name) do
    case resolve_and_stream(model_name, body, key_name) do
      {:ok, stream, deployment} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-context-length", to_string(deployment.context || 0))
          |> put_resp_header("x-model-name", deployment.upstream_model)
          |> send_chunked(200)

        conn =
          Enum.reduce_while(stream, conn, fn
            :done, conn ->
              {:halt, conn}

            chunk, conn ->
              case chunk(conn, "data: #{Jason.encode!(chunk)}\n\n") do
                {:ok, conn} -> {:cont, conn}
                {:error, _} -> {:halt, conn}
              end
          end)

        # Send [DONE] marker
        case chunk(conn, "data: [DONE]\n\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end

      {:error, %{type: :not_found}} ->
        send_json(conn, 404, error_body("Model '#{model_name}' not found", "not_found"))

      {:error, %{type: :forbidden}} ->
        send_json(conn, 403, error_body("Access denied to '#{model_name}'", "access_forbidden"))

      {:error, err} ->
        send_json(conn, 502, error_body(inspect(err), "upstream_error"))
    end
  end

  defp resolve_and_stream(model_name, body, key_name) do
    case Llmgateway.Router.resolve_model(model_name, key: key_name) do
      {:ok, deployment, fallbacks} ->
        try_stream_with_fallbacks(deployment, fallbacks, body, key_name)

      {:error, :not_found} ->
        {:error, %{type: :not_found}}

      {:error, :forbidden, fallbacks} ->
        try_stream_fallback_list(fallbacks, body, key_name)

      {:error, :forbidden} ->
        {:error, %{type: :forbidden}}
    end
  end

  defp try_stream_with_fallbacks(deployment, fallbacks, body, key_name) do
    case Llmgateway.Stream.call(deployment, body) do
      {:ok, stream} -> {:ok, stream, deployment}
      {:error, _reason} when fallbacks != [] ->
        Logger.warning("Stream #{deployment.name} failed, trying fallbacks: #{inspect(fallbacks)}")
        try_stream_fallback_list(fallbacks, body, key_name)
      {:error, reason} -> {:error, reason}
    end
  end

  defp try_stream_fallback_list([], _body, _key_name) do
    {:error, %{type: :all_failed, message: "All stream fallbacks failed"}}
  end

  defp try_stream_fallback_list([fb_name | rest], body, key_name) do
    case Llmgateway.Router.resolve_model(fb_name, key: key_name) do
      {:ok, deployment, more_fallbacks} ->
        remaining = Enum.uniq(rest ++ more_fallbacks) -- [fb_name]
        Logger.debug("Stream trying #{fb_name}, remaining chain: #{inspect(remaining)}")
        case Llmgateway.Stream.call(deployment, body) do
          {:ok, stream} -> {:ok, stream, deployment}
          {:error, reason} ->
            Logger.warning("Stream fallback #{fb_name} failed: #{inspect(reason)}, remaining: #{inspect(remaining)}")
            try_stream_fallback_list(remaining, body, key_name)
        end

      {:error, :forbidden, more_fallbacks} ->
        remaining = Enum.uniq(rest ++ more_fallbacks) -- [fb_name]
        Logger.warning("Stream fallback #{fb_name} forbidden, remaining: #{inspect(remaining)}")
        try_stream_fallback_list(remaining, body, key_name)

      {:error, reason} ->
        Logger.warning("Stream fallback #{fb_name} resolve failed: #{inspect(reason)}")
        try_stream_fallback_list(rest, body, key_name)
    end
  end

  # ── Anthropic-format handlers ─────────────────────────────

  defp handle_anthropic_completion(conn, model_name, canonical_body, key_name) do
    case Llmgateway.generate_text(model_name, canonical_body, key: key_name) do
      {:ok, response} ->
        anthropic_response = Llmgateway.Convert.InboundAnthropic.from_canonical(response)

        conn
        |> put_context_header(model_name, key_name)
        |> send_json(200, anthropic_response)

      {:error, %{type: :not_found}} ->
        send_anthropic_error(conn, 404, "not_found_error", "Model '#{model_name}' not found")

      {:error, %{type: :forbidden}} ->
        send_anthropic_error(conn, 403, "permission_error", "Access denied to '#{model_name}'")

      {:error, %{type: :rate_limit} = err} ->
        send_anthropic_error(conn, 429, "rate_limit_error", err[:message] || "Rate limited")

      {:error, %{message: msg}} ->
        send_anthropic_error(conn, 502, "api_error", msg)

      {:error, err} ->
        send_anthropic_error(conn, 500, "api_error", format_error(err))
    end
  end

  defp handle_anthropic_stream(conn, model_name, canonical_body, key_name) do
    case resolve_and_stream(model_name, canonical_body, key_name) do
      {:ok, stream, deployment} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-context-length", to_string(deployment.context || 0))
          |> send_chunked(200)

        state = %{block_index: 0}

        {conn, _state} =
          Enum.reduce_while(stream, {conn, state}, fn
            :done, {conn, state} ->
              {:halt, {conn, state}}

            chunk, {conn, state} ->
              case Llmgateway.Convert.InboundAnthropic.chunk_to_anthropic_events(chunk, state) do
                {:ok, events, new_state} ->
                  result =
                    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, c} ->
                      case chunk(c, "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n") do
                        {:ok, c} -> {:cont, {:ok, c}}
                        {:error, _} -> {:halt, {:error, c}}
                      end
                    end)

                  case result do
                    {:ok, conn} -> {:cont, {conn, new_state}}
                    {:error, conn} -> {:halt, {conn, new_state}}
                  end

                {:skip, new_state} ->
                  {:cont, {conn, new_state}}
              end
          end)

        conn

      {:error, %{type: :not_found}} ->
        send_anthropic_error(conn, 404, "not_found_error", "Model '#{model_name}' not found")

      {:error, err} ->
        send_anthropic_error(conn, 500, "api_error", inspect(err))
    end
  end

  defp send_anthropic_error(conn, status, type, message) do
    send_json(conn, status, %{
      "type" => "error",
      "error" => %{"type" => type, "message" => message}
    })
  end

  # ── Plugs ─────────────────────────────────────────────────


  defp parse_body(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct] ->
        if String.starts_with?(ct, "application/json") do
          case Plug.Conn.read_body(conn, length: 10_000_000) do
            {:ok, raw, conn} ->
              case Jason.decode(raw) do
                {:ok, parsed} -> %{conn | body_params: parsed}
                {:error, _} -> conn |> send_json(400, error_body("Invalid JSON", "invalid_request")) |> halt()
              end

            {:more, _, conn} ->
              conn |> send_json(413, error_body("Request body too large", "invalid_request")) |> halt()

            {:error, _reason} ->
              conn |> send_json(400, error_body("Failed to read body", "invalid_request")) |> halt()
          end
        else
          conn
        end

      _ ->
        conn
    end
  end

  defp authenticate(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    if conn.request_path == "/health" do
      assign(conn, :key_name, nil)
    else
      case extract_bearer(conn) do
        nil ->
          if Process.whereis(Llmgateway.Router) do
            # Check if keys are configured — if so, require auth
            case Llmgateway.Router.list_models() do
              _ ->
                # Allow through with nil key — resolve_model will enforce per-model access
                assign(conn, :key_name, nil)
            end
          else
            conn |> send_json(503, error_body("Router not started", "service_unavailable")) |> halt()
          end

        token ->
          case Llmgateway.resolve_key(token) do
            {:ok, key_name} ->
              assign(conn, :key_name, key_name)

            {:error, :invalid_key} ->
              conn |> send_json(401, error_body("Invalid API key", "authentication_error")) |> halt()
          end
      end
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ ->
        # Also check x-api-key header (Anthropic style)
        case Plug.Conn.get_req_header(conn, "x-api-key") do
          [key] -> key
          _ -> nil
        end
    end
  end

  # ── Helpers ───────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_context_header(conn, model_name, key_name) do
    # Look up context length for the model
    case Llmgateway.Router.resolve_model(model_name, key: key_name) do
      {:ok, deployment, _} when is_integer(deployment.context) ->
        conn
        |> put_resp_header("x-context-length", Integer.to_string(deployment.context))
        |> put_resp_header("x-model-name", deployment.upstream_model)

      _ ->
        conn
    end
  end

  defp error_body(message, type, details \\ nil) do
    error = %{"message" => message, "type" => type}
    error = if details, do: Map.put(error, "details", details), else: error
    %{"error" => error}
  end
  defp format_error(%{message: msg}), do: msg
  defp format_error(err) when is_binary(err), do: err
  defp format_error(err), do: inspect(err)

end
