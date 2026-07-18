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

  match _ do
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

      {:error, %{type: :all_failed} = err} ->
        send_json(conn, 502, error_body("All deployments failed", "upstream_error", err[:errors]))

      {:error, %{type: :transport_error} = err} ->
        send_json(conn, 502, error_body(err[:reason] |> inspect(), "upstream_error"))

      {:error, %{type: :unknown_error} = err} ->
        send_json(conn, 502, error_body(inspect(err[:reason]), "upstream_error"))

      {:error, err} ->
        send_json(conn, 500, error_body(inspect(err), "internal_error"))
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
      {:ok, deployment, _fallbacks} ->
        case Llmgateway.Stream.call(deployment, body) do
          {:ok, stream} -> {:ok, stream, deployment}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, %{type: :not_found}}

      {:error, :forbidden} ->
        {:error, %{type: :forbidden}}

      {:error, :forbidden, _} ->
        {:error, %{type: :forbidden}}
    end
  end

  # ── Plugs ─────────────────────────────────────────────────

  defp parse_body(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct] when ct in ["application/json", "application/json; charset=utf-8"] ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        case Jason.decode(raw) do
          {:ok, parsed} -> %{conn | body_params: parsed}
          {:error, _} -> conn |> send_json(400, error_body("Invalid JSON", "invalid_request")) |> halt()
        end

      _ ->
        conn
    end
  end

  defp authenticate(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    # Health check doesn't need auth
    if conn.request_path == "/health" do
      assign(conn, :key_name, nil)
    else
      case extract_bearer(conn) do
        nil ->
          # No keys configured = allow all
          if Process.whereis(Llmgateway.Router) do
            assign(conn, :key_name, nil)
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
      _ -> nil
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
end
