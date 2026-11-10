defmodule Llmgateway.AnthropicRoutes do
  @moduledoc """
  Anthropic-format (`/v1/messages`) completion and streaming handlers.
  """
  import Plug.Conn

  require Logger

  alias Llmgateway.{Fallback, Responses, SSE, Usage}

  def handle_completion(conn, model_name, canonical_body, key_name, app) do
    case generate_text(model_name, canonical_body, key_name, app) do
      {:ok, response, deployment} ->
        anthropic_response = Llmgateway.Convert.InboundAnthropic.from_canonical(response)

        conn =
          conn
          |> Responses.put_context_header(deployment)
          |> Responses.send_json(200, anthropic_response)

        Usage.record(deployment, response["usage"],
          requested_model: model_name,
          key: key_name,
          app: app,
          stream: false
        )

        conn

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
          SSE.stream_loop(stream, conn, state, deployment, rid, &reduce/2, &usage/1, &finish/1)

        took = System.monotonic_time(:millisecond) - (final_state[:started_at] || started_at)

        Logger.info(
          "[anthropic-stream] rid=#{rid} finished model=#{deployment.upstream_model} " <>
            "deployment=#{deployment.name} blocks=#{final_state[:next_idx] || 0} " <>
            "usage=#{inspect(Map.get(final_state, :usage))} ms=#{took}"
        )

        Usage.record(deployment, final_state[:usage],
          requested_model: model_name,
          key: key_name,
          app: app,
          stream: true
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
        new_state = put_usage(new_state, chunk, state)
        log_events(events, new_state.rid)
        {:ok, Enum.map(events, &event_frame/1), new_state}

      {:skip, new_state} ->
        # A chunk with no events can still carry the stream's usage
        # (the OpenAI `stream_options.include_usage` terminal chunk).
        {:skip, put_usage(new_state, chunk, state)}
    end
  end

  defp put_usage(new_state, chunk, state) do
    Map.put(new_state, :usage, chunk["usage"] || Map.get(state, :usage))
  end

  # End-of-stream events: message_delta (usage, stop_reason) then message_stop.
  defp finish(state) do
    case Llmgateway.Convert.InboundAnthropic.finish_message(state) do
      {:ok, events, new_state} ->
        log_events(events, new_state.rid)
        {:ok, Enum.map(events, &event_frame/1), new_state}

      :skip ->
        {:skip, state}
    end
  end

  defp event_frame(event) do
    "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
  end

  # Permanent per-request trace. Lifecycle events (start/stop/message)
  # are :info so a broken stream is visible even with debug off;
  # high-frequency content_block_delta stays at :debug.
  defp log_events(events, rid) do
    Enum.each(events, fn event ->
      if event["type"] == "content_block_delta" do
        Logger.debug("[anthropic-stream] rid=#{rid} #{format_stream_event(event)}")
      else
        Logger.info("[anthropic-stream] rid=#{rid} #{format_stream_event(event)}")
      end
    end)
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
