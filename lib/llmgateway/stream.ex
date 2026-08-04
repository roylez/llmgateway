defmodule Llmgateway.Stream do
  @moduledoc """
  SSE streaming support for LLM provider responses.

  Uses Req's `into: :self` to stream responses, parses SSE events,
  converts them to OpenAI format if needed, and yields chunks.
  """

  require Logger

  alias Llmgateway.{Auth, Convert, Convert.ResponsesAPI, Deployment}

  @doc """
  Execute a streaming request and return an enumerable of OpenAI-format SSE chunks.

  Each yielded value is a map (decoded JSON) in OpenAI chat.completion.chunk format.
  The caller should encode and forward these as SSE `data:` lines.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  def call(%Deployment{} = deployment, body, opts \\ []) do
    timeout = opts[:timeout] || 120_000

    {provider_body, _warnings} = Convert.to_provider(deployment, body)

    provider_body =
      provider_body
      |> Map.put("model", deployment.upstream_model)
      |> Map.put("stream", true)
      |> Map.delete("_llmgateway")

    result =
      case Auth.prepare_request(deployment, provider_body, timeout) do
        {:ok, req, url, request_body, is_responses} ->
          Logger.debug(
            "[stream] rid=#{opts[:rid] || "-"} send url=#{url} model=#{deployment.upstream_model}"
          )

          case Req.post(req, url: url, json: request_body, into: :self) do
            {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
              stream =
                Llmgateway.Stream.build_stream(resp.body, deployment, is_responses, opts[:rid])

              {:ok, stream}

            {:ok, %Req.Response{status: status, body: body}} ->
              error_body = drain_body(body)
              {:error, classify_error(status, error_body, deployment)}

            {:error, reason} ->
              {:error, %{type: :transport_error, reason: reason, deployment: deployment.name}}
          end

        {:error, reason} ->
          {:error,
           %{
             type: :client_error,
             message: "Auth failed: #{inspect(reason)}",
             deployment: deployment.name
           }}
      end

    result
  end

  # ── SSE parsing ───────────────────────────────────────────

  defp to_sse_stream(body, _resp) when is_struct(body, Req.Response.Async), do: body
  defp to_sse_stream(body, _resp) when is_binary(body), do: [body]
  defp to_sse_stream(body, _resp), do: body

  @doc """
  Build the OpenAI-format SSE enumerable for a given upstream response body.

  Passes through any streamable body (`Req.Response.Async` or binary) and, while
  yielding the decoded chunks, accumulates per-request diagnostics. A terminal
  `{:stream_stats, stats}` element is emitted once the upstream stream is fully
  consumed, which the server logs via `log_stats/4`.
  """
  def build_stream(resp_body, %Deployment{} = deployment, is_responses, rid) do
    resp_body
    |> to_sse_stream(%{})
    |> Stream.transform("", &buffer_sse_lines/2)
    |> Stream.transform(
      fn -> new_stats(rid) end,
      &track_chunk(&1, &2, deployment, is_responses),
      &finish_stats/1,
      fn _stats -> :ok end
    )
  end

  @doc false
  def parse_sse_lines(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.trim_leading(&1, "data: "))
  end

  defp buffer_sse_lines(chunk, buffer) when is_binary(chunk) do
    combined = buffer <> chunk
    lines = String.split(combined, "\n")

    {complete, [remainder]} = Enum.split(lines, -1)

    data_lines =
      complete
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))

    {data_lines, remainder}
  end

  # ── Stream diagnostics ────────────────────────────────────

  # How many chars of the raw upstream SSE to keep for the tail in diagnostics.
  @tail_chars 600

  defp new_stats(rid) do
    %{
      rid: rid,
      chunks: 0,
      text_deltas: 0,
      thinking_deltas: 0,
      tool_deltas: 0,
      skipped: %{},
      finish: nil,
      done: false,
      decode_failures: 0,
      bytes: 0,
      tail: ""
    }
  end

  defp track_chunk(data, stats, deployment, is_responses) do
    combined = stats.tail <> data <> "\n"
    tail_len = String.length(combined)

    tail =
      if tail_len > @tail_chars do
        String.slice(combined, tail_len - @tail_chars, @tail_chars)
      else
        combined
      end

    stats = %{stats | bytes: stats.bytes + byte_size(data), tail: tail}

    case decode_and_convert(data, deployment, is_responses) do
      :error ->
        {[], %{stats | decode_failures: stats.decode_failures + 1}}

      {:ok, items} ->
        {items, Enum.reduce(items, stats, &tally_chunk/2)}

      {:ok, items, %{skipped: skip_count}} ->
        combined = Map.merge(stats.skipped, skip_count, fn _k, a, b -> a + b end)
        {items, Enum.reduce(items, %{stats | skipped: combined}, &tally_chunk/2)}
    end
  end

  # Terminal element (`last_fun`) emitted once the upstream stream is exhausted.
  defp finish_stats(stats), do: {[{:stream_stats, stats}], stats}

  defp decode_and_convert("[DONE]", _deployment, _is_responses), do: {:ok, [:done]}

  # Returns `{:ok, [chunk]}`, `{:ok, []}` for skipped events, or `:error` when
  # a raw SSE data line could not be decoded as JSON (i.e. it was dropped).
  defp decode_and_convert(data, deployment, is_responses) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, event} ->
        result =
          if is_responses do
            ResponsesAPI.stream_event_to_chunk(event)
          else
            Convert.stream_event_to_canonical(deployment, event)
          end

        case result do
          {:ok, chunk} -> {:ok, [chunk]}
          :done -> {:ok, [:done]}
          :skip -> {:ok, [], skipped_event(event)}
        end

      {:error, reason} ->
        Logger.debug(
          "Failed to decode SSE event: #{String.slice(data, 0, 200)} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  # Tag skipped events so the diagnostics can show which upstream event types
  # carried content that the conversion chose not to forward.
  defp skipped_event(event) do
    type = event["type"] || "?"
    tag = type <> ":" <> (event["schema_name"] || "-")
    %{skipped: Map.update(%{}, tag, 1, &(&1 + 1))}
  end

  defp tally_chunk(:done, stats), do: %{stats | done: true}

  defp tally_chunk(%{"choices" => choices}, stats) when is_list(choices) do
    case List.first(choices) do
      nil ->
        stats

      choice ->
        delta = choice["delta"] || %{}
        stats = %{stats | chunks: stats.chunks + 1}

        stats =
          if is_binary(delta["content"]) and delta["content"] != "" do
            %{stats | text_deltas: stats.text_deltas + 1}
          else
            stats
          end

        stats =
          if thinking_text(delta) do
            %{stats | thinking_deltas: stats.thinking_deltas + 1}
          else
            stats
          end

        stats =
          if is_list(delta["tool_calls"]) and delta["tool_calls"] != [] do
            %{stats | tool_deltas: stats.tool_deltas + 1}
          else
            stats
          end

        stats =
          if is_binary(choice["finish_reason"]),
            do: %{stats | finish: choice["finish_reason"]},
            else: stats

        stats
    end
  end

  defp tally_chunk(_, stats), do: stats

  defp thinking_text(delta) do
    (is_binary(delta["reasoning_content"]) and delta["reasoning_content"] != "") or
      (is_binary(delta["reasoning"]) and delta["reasoning"] != "")
  end

  @doc """
  Log a per-request stream summary.

  Normal streams log one `:debug` line with teardown counts. Streams that
  completed without any usable assistant content (no text and no tool calls -
  the "empty stop" signature, including reasoning-only turns) or that dropped
  undecodable SSE events are logged at `:warning` with the raw upstream SSE
  tail, so an empty client-facing response is diagnosable from the server log.
  """
  def log_stats(%Deployment{} = deployment, rid, stats, usage) do
    # Usable = text or tool calls. Reasoning/thinking alone still leaves the
    # client with nothing to run, so it counts as an empty stop.
    empty = stats.text_deltas == 0 and stats.tool_deltas == 0

    base =
      "[stream-stats] rid=#{rid} model=#{deployment.name} " <>
        "upstream=#{deployment.upstream_model} chunks=#{stats.chunks} " <>
        "text=#{stats.text_deltas} thinking=#{stats.thinking_deltas} " <>
        "tools=#{stats.tool_deltas} skipped=#{inspect(stats.skipped)} " <>
        "finish=#{stats.finish || "none"} done=#{stats.done} " <>
        "failures=#{stats.decode_failures} bytes=#{stats.bytes} " <>
        "usage=#{inspect(usage || %{})}"

    if empty or stats.decode_failures > 0 do
      Logger.warning(base <> "\n  [stream-stats] upstream raw tail: " <> inspect(stats.tail))
    else
      Logger.debug(base)
    end
  end

  # ── Error helpers ─────────────────────────────────────────

  defp drain_body(body) when is_binary(body), do: body

  defp drain_body(body) do
    try do
      Enum.join(body, "")
    rescue
      _ -> ""
    end
  end

  defp classify_error(429, body, deployment) do
    %{
      type: :rate_limit,
      status: 429,
      message: error_slice(body),
      deployment: deployment.name
    }
  end

  defp classify_error(status, body, deployment) when status >= 500 do
    %{
      type: :server_error,
      status: status,
      message: error_slice(body),
      deployment: deployment.name
    }
  end

  defp classify_error(status, body, deployment) do
    %{
      type: :client_error,
      status: status,
      message: error_slice(body),
      deployment: deployment.name
    }
  end

  # Upstream status bodies are drained to a string; keep a bounded slice so the
  # provider's reason (e.g. Copilot's 'Unsupported parameter: …') surfaces in
  # fallback error details and warnings instead of being discarded.
  defp error_slice(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp error_slice(_), do: nil
end
