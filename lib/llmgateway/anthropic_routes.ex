defmodule Llmgateway.AnthropicRoutes do
  @moduledoc """
  Anthropic-format (`/v1/messages`) completion and streaming handlers.
  """
  import Plug.Conn

  require Logger

  alias Llmgateway.{Fallback, Responses, SSE}

  def handle_completion(conn, model_name, canonical_body, key_name, app) do
    case generate_text(model_name, canonical_body, key_name, app) do
      {:ok, response, deployment} ->
        anthropic_response = Llmgateway.Convert.InboundAnthropic.from_canonical(response)

        conn
        |> Responses.put_context_header(deployment)
        |> Responses.send_json(200, anthropic_response)

      {:error, %{type: :not_found}} ->
        send_anthropic_error(conn, 404, "not_found_error", "Model '#{model_name}' not found")

      {:error, %{type: :forbidden}} ->
        send_anthropic_error(conn, 403, "permission_error", "Access denied to '#{model_name}'")

      {:error, %{type: :rate_limit} = err} ->
        send_anthropic_error(conn, 429, "rate_limit_error", err[:message] || "Rate limited")

      {:error, %{message: msg}} ->
        send_anthropic_error(conn, 502, "api_error", msg)

      {:error, err} ->
        send_anthropic_error(conn, 500, "api_error", Responses.format_error(err))
    end
  end

  def handle_stream(conn, model_name, canonical_body, key_name, app, rid) do
    started_at = System.monotonic_time(:millisecond)

    case stream_text(model_name, canonical_body, key_name, app, rid) do
      {:ok, stream, deployment} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-context-length", to_string(deployment.context || 0))
          |> put_resp_header("x-model-name", deployment.upstream_model)
          |> send_chunked(200)

        state = %{rid: rid, started_at: started_at}

        {conn, final_state} =
          SSE.stream_loop(stream, conn, state, deployment, rid, &reduce/2, &usage/1)

        took = System.monotonic_time(:millisecond) - (final_state[:started_at] || started_at)

        Logger.info(
          "[anthropic-stream] rid=#{rid} finished model=#{deployment.upstream_model} " <>
            "deployment=#{deployment.name} blocks=#{final_state[:next_idx] || 0} " <>
            "usage=#{inspect(Map.get(final_state, :usage))} ms=#{took}"
        )

        conn

      {:error, %{type: :not_found}} ->
        send_anthropic_error(conn, 404, "not_found_error", "Model '#{model_name}' not found")

      {:error, err} ->
        send_anthropic_error(conn, 500, "api_error", inspect(err))
    end
  end


  defp send_anthropic_error(conn, status, type, message) do
    Responses.send_json(conn, status, %{
      "type" => "error",
      "error" => %{"type" => type, "message" => message}
    })
  end

  defp reduce(chunk, state) do
    case Llmgateway.Convert.InboundAnthropic.chunk_to_anthropic_events(chunk, state) do
      {:ok, events, new_state} ->
        usage = chunk["usage"] || Map.get(state, :usage)
        new_state = Map.put(new_state, :usage, usage)

        # Permanent per-request trace. Lifecycle events (start/stop/message)
        # are :info so a broken stream is visible even with debug off;
        # high-frequency content_block_delta stays at :debug.
        Enum.each(events, fn event ->
          if event["type"] == "content_block_delta" do
            Logger.debug("[anthropic-stream] rid=#{new_state.rid} #{format_stream_event(event)}")
          else
            Logger.info("[anthropic-stream] rid=#{new_state.rid} #{format_stream_event(event)}")
          end
        end)

        frames =
          Enum.map(events, fn event ->
            "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
          end)

        {:ok, frames, new_state}

      {:skip, new_state} ->
        {:skip, new_state}
    end
  end

  defp usage(state), do: Map.get(state, :usage)

  defp format_stream_event(%{"type" => "message_start"} = ev) do
    "event=message_start model=#{get_in(ev, ["message", "model"]) || "?"}"
  end

  defp format_stream_event(%{"type" => "content_block_start"} = ev) do
    "event=content_block_start index=#{ev["index"]} type=#{get_in(ev, ["content_block", "type"]) || "?"}"
  end

  defp format_stream_event(%{"type" => "content_block_stop"} = ev) do
    "event=content_block_stop index=#{ev["index"]}"
  end

  defp format_stream_event(%{"type" => "message_delta"} = ev) do
    "event=message_delta stop_reason=#{get_in(ev, ["delta", "stop_reason"]) || "?"} usage=#{inspect(ev["usage"])}"
  end

  defp format_stream_event(%{"type" => "message_stop"}), do: "event=message_stop"

  defp format_stream_event(%{"type" => "content_block_delta"} = ev) do
    "event=content_block_delta index=#{ev["index"]} kind=#{get_in(ev, ["delta", "type"]) || "?"}"
  end

  defp format_stream_event(ev), do: "event=#{ev["type"]}"

  defp generate_text(model, body, key_name, app) do
    Llmgateway.generate_text(model, body, key: key_name, app: app)
  end

  defp stream_text(model, body, key_name, app, rid) do
    Fallback.stream(model, body, key: key_name, app: app, rid: rid)
  end
end
