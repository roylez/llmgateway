defmodule Llmgateway.Stream do
  @moduledoc """
  SSE streaming support for LLM provider responses.

  Uses Req's `into: :self` to stream responses, parses SSE events,
  converts them to OpenAI format if needed, and yields chunks.
  """

  require Logger

  alias Llmgateway.{Convert, Convert.ResponsesAPI, Deployment, Upstream}

  @doc """
  Execute a streaming request and return an enumerable of OpenAI-format SSE chunks.

  Each yielded value is a map (decoded JSON) in OpenAI chat.completion.chunk format.
  The caller should encode and forward these as SSE `data:` lines.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  def call(%Deployment{} = deployment, body, opts \\ []) do
    case Upstream.execute(deployment, body, Keyword.put(opts, :stream, true)) do
      {:ok, %Req.Response{body: resp_body}, _warnings, is_responses} ->
        resp_body
        |> Llmgateway.Stream.build_stream(deployment, is_responses, opts[:rid])
        |> preflight(deployment, opts[:rid])
        |> log_empty_stream(deployment, opts[:rid])

      {:error, error} ->
        {:error, error}
    end
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
  def preflight(stream, deployment \\ nil, rid \\ nil) do
    try do
      case Enumerable.reduce(stream, {:cont, []}, fn item, buffered ->
             buffered = [item | buffered]

             if usable?(item) do
               {:suspend, buffered}
             else
               {:cont, buffered}
             end
           end) do
        {:suspended, buffered, continuation} ->
          {:ok, resume_stream(Enum.reverse(buffered), continuation, deployment, rid)}

        {status, buffered} when status in [:done, :halted] ->
          {:error,
           %{
             type: :server_error,
             status: 502,
             message: "Upstream stream completed without text or tool calls",
             stream_stats: stream_stats(buffered)
           }}
      end
    rescue
      error in Finch.TransportError ->
        log_transport_error(deployment, rid, error.reason)
        {:error, transport_error(error)}
    end
  end

  defp usable?(%{"choices" => [choice | _]}) do
    delta = choice["delta"] || %{}

    (is_binary(delta["content"]) and delta["content"] != "") or
      thinking_text(delta) or
      (is_list(delta["tool_calls"]) and delta["tool_calls"] != [])
  end

  defp usable?(_), do: false

  defp resume_stream(buffered, continuation, deployment, rid) do
    Stream.resource(
      fn -> {buffered, continuation} end,
      fn
        {[item | rest], continuation} ->
          {[item], {rest, continuation}}

        {[], nil} ->
          {:halt, {[], nil}}

        {[], continuation} ->
          try do
            case continuation.({:cont, []}) do
              {:suspended, items, next} -> {Enum.reverse(items), {[], next}}
              {status, items} when status in [:done, :halted] -> {Enum.reverse(items), {[], nil}}
            end
          rescue
            error in Finch.TransportError ->
              log_transport_error(deployment, rid, error.reason)
              {:halt, {[], continuation}}
          end
      end,
      fn
        {_, nil} -> :ok
        {_, continuation} -> continuation.({:halt, []})
      end
    )
  end

  defp transport_error(error), do: %{type: :transport_error, reason: error.reason}

  defp log_transport_error(nil, _rid, reason) do
    Logger.warning("[stream] upstream transport error #{inspect(reason)}")
  end

  defp log_transport_error(deployment, rid, reason) do
    Logger.warning(
      "[stream] rid=#{rid || "-"} deployment=#{deployment.name} transport error #{inspect(reason)}"
    )
  end

  defp log_empty_stream({:error, %{stream_stats: stats} = error}, deployment, rid) do
    log_stats(deployment, rid, stats, nil)
    {:error, error}
  end

  defp log_empty_stream(result, _deployment, _rid), do: result

  defp stream_stats(buffered) do
    buffered
    |> Enum.find_value(fn
      {:stream_stats, stats} -> stats
      _ -> nil
    end)
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
      synthetic: false,
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
  # The upstream never emitted a terminal chunk carrying a finish_reason, so
  # clients have no stop signal (Anthropic clients in particular never get a
  # message_stop and wait for the turn to finish). Synthesize a well-formed
  # terminal chunk with finish_reason "stop" — end_turn on the Anthropic
  # side — before the diagnostics marker. If the upstream ends normally
  # (chunk with finish_reason, or the responder already closed blocks), no
  # synthesis happens.
  defp finish_stats(%{finish: nil} = stats) do
    stats = %{stats | synthetic: true}

    {
      [
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
        {:stream_stats, stats}
      ],
      stats
    }
  end

  defp finish_stats(stats), do: {[{:stream_stats, stats}], stats}

  defp decode_and_convert("[DONE]", _deployment, _is_responses), do: {:ok, [:done]}

  # Returns `{:ok, [chunk]}`, `{:ok, []}` for skipped events, or `:error` when
  # a raw SSE data line could not be decoded as JSON (i.e. it was dropped).
  defp decode_and_convert(data, deployment, is_responses) when is_binary(data) do
    case Jason.decode(data) do
      # Some aggregator upstreams close the stream with a metadata event
      # (e.g. {"choices":[],"cost":"0"}) instead of a terminal chunk or
      # [DONE]. It carries no delta and no finish_reason — forward nothing.
      {:ok, %{"choices" => []}} ->
        {:ok, []}

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

  Normal streams log one `:debug` line with teardown counts. A warning with
  the raw upstream SSE tail is emitted for streams that dropped undecodable
  SSE events, or that ended with nothing to show the client:

  - an empty stop — no text, no tool calls, no thinking: the upstream returned
    nothing at all;
  - a reasoning-only turn that leaked raw thinking — the model's whole reply
    stayed in `reasoning_content` and never reached `content`. Harnesses that
    request reasoning (Codex, opencode) render this fine, so it is only
    notable, but harnesses that do not (Claude Code) show an empty reply.
  Converted reasoning (`thinking_deltas == 0`) is ordinary text to the client
  and logs at `:debug` like any other content.
  """
  def log_stats(%Deployment{} = deployment, rid, stats, usage) do
    empty_stop? =
      stats.text_deltas == 0 and stats.tool_deltas == 0 and stats.thinking_deltas == 0

    raw_thinking_only? =
      stats.text_deltas == 0 and stats.tool_deltas == 0 and stats.thinking_deltas > 0

    base =
      "[stream-stats] rid=#{rid} model=#{deployment.name} " <>
        "upstream=#{deployment.upstream_model} chunks=#{stats.chunks} " <>
        "text=#{stats.text_deltas} thinking=#{stats.thinking_deltas} " <>
        "tools=#{stats.tool_deltas} skipped=#{inspect(stats.skipped)} " <>
        "finish=#{stats.finish || "none"} done=#{stats.done} " <>
        "synthetic=#{stats.synthetic} " <>
        "failures=#{stats.decode_failures} bytes=#{stats.bytes} " <>
        "usage=#{inspect(usage || %{})}"

    if stats.decode_failures > 0 or empty_stop? or raw_thinking_only? do
      Logger.warning(base <> "\n  [stream-stats] upstream raw tail: " <> inspect(stats.tail))
    else
      Logger.debug(base)
    end
  end
end
