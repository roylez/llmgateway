defmodule Llmgateway.Convert.DSML do
  @moduledoc """
  Extracts DeepSeek DSML tool-call markup from assistant text.

  DeepSeek models (V3.2, V4, V4.1) invoke tools by writing markup in the
  text channel instead of structured `tool_calls`:

      <｜DSML｜ calls>
      <｜DSML｜ invoke name="get_weather">
      <｜DSML｜ parameter name="city" string="true">Hangzhou</｜DSML｜ parameter>
      <｜DSML｜ parameter name="days" string="false">3</｜DSML｜ parameter>
      </｜DSML｜ invoke>
      </｜DSML｜ calls>

  (V3.2 writes `<｜DSML｜function_calls>` / `<｜DSML｜invoke …>` without the
  space, V4 writes `<｜DSML｜tool_calls>`.) Some providers forward this
  verbatim as content; harnesses cannot execute it, the raw markup leaks to
  the user, and the agent stalls waiting for tool results.

  This module re-emits the text with complete invokes converted to
  OpenAI-style tool calls. Streaming callers use `init/0` + `feed/2` +
  `finish/1`; `extract/1` wraps them for a complete string. Text after a
  closed block is dropped, matching vLLM's reference parsers. At long
  context the model may omit the opening block tag (vllm-project/vllm#48931),
  so a bare invoke tag also opens a block.
  """

  require Logger

  alias Llmgateway.Deployment

  # V3.2 and V4 share the invoke/parameter tags; only the wrapper differs.
  @shared_tags %{
    invoke_start: "<｜DSML｜invoke",
    invoke_end: "</｜DSML｜invoke>",
    param_start: "<｜DSML｜parameter",
    param_end: "</｜DSML｜parameter>"
  }

  @dialects [
    Map.merge(@shared_tags, %{
      block_start: "<｜DSML｜function_calls>",
      block_end: "</｜DSML｜function_calls>"
    }),
    Map.merge(@shared_tags, %{
      block_start: "<｜DSML｜tool_calls>",
      block_end: "</｜DSML｜tool_calls>"
    }),
    %{
      block_start: "<｜DSML｜ calls>",
      block_end: "</｜DSML｜ calls>",
      invoke_start: "<｜DSML｜ invoke",
      invoke_end: "</｜DSML｜ invoke>",
      param_start: "<｜DSML｜ parameter",
      param_end: "</｜DSML｜ parameter>"
    }
  ]

  @block_starts for d <- @dialects, do: d.block_start
  @block_ends Enum.uniq(for d <- @dialects, do: d.block_end)
  @invoke_starts Enum.uniq(for d <- @dialects, do: d.invoke_start)
  @anchors Enum.uniq(@block_starts ++ @invoke_starts)

  @anchor_dialect Map.new(
                    Enum.flat_map(@dialects, fn d -> [{d.block_start, d}, {d.invoke_start, d}] end)
                  )

  # ── Public API ────────────────────────────────────────────

  @doc """
  Whether DSML extraction applies: DeepSeek-family upstream model and a
  request that carries tools.
  """
  def enabled?(%Deployment{upstream_model: model}, body) do
    is_binary(model) and String.contains?(String.downcase(model), "deepseek") and
      is_list(body["tools"]) and body["tools"] != []
  end

  @doc "Initial scanner state."
  def init, do: %{mode: :text, buffer: "", calls: 0}

  @doc """
  Feed one text delta. Returns `{emissions, state}` where each emission is
  `{:text, visible_text}` or `{:tool_call, %{index:, name:, arguments:}}`
  (arguments is a JSON string). Text that may be the start of a marker is
  buffered until the next feed disambiguates it.
  """
  def feed(state, text) do
    step(%{state | buffer: state.buffer <> text}, [])
  end

  @doc """
  Close the stream. Flushes buffered plain text; buffered markup that never
  completed an invoke is dropped (forwarding it raw is the leak this module
  fixes).
  """
  def finish(%{mode: :text, buffer: buffer} = state) do
    out = drop_last(buffer, hold_len(buffer, @anchors))
    state = %{state | buffer: ""}
    if out == "", do: {[], state}, else: {[{:text, out}], state}
  end

  def finish(%{mode: {:block, _}, buffer: buffer} = state) do
    if buffer != "" do
      Logger.warning(
        "[dsml] dropped incomplete tool-call markup: #{inspect(String.slice(buffer, 0, 80))}"
      )
    end

    {[], %{state | buffer: ""}}
  end

  def finish(%{mode: :done} = state), do: {[], %{state | buffer: ""}}

  @doc """
  One-shot extraction from complete text. Returns `{visible_text, calls}`
  where each call is `%{name:, arguments:}` with JSON-string arguments.
  """
  def extract(text) when is_binary(text) do
    {emitted, state} = feed(init(), text)
    {flushed, _state} = finish(state)

    {texts, calls} =
      (emitted ++ flushed)
      |> Enum.split_with(&match?({:text, _}, &1))

    text = for {:text, t} <- texts, into: "", do: t
    calls = for {:tool_call, c} <- calls, do: %{name: c.name, arguments: c.arguments}
    {text, calls}
  end

  @doc """
  Rewrite a canonical (OpenAI-format) non-streaming response: DSML markup in
  the assistant content becomes structured `tool_calls`, and a `stop`
  finish_reason becomes `tool_calls` when any were extracted.
  """
  def rewrite_response(response) when is_map(response) do
    case response["choices"] do
      [%{"message" => %{"content" => content} = message} = choice | _] when is_binary(content) ->
        {text, calls} = extract(content)

        if calls == [] do
          response
        else
          tool_calls =
            (message["tool_calls"] || []) ++
              Enum.map(calls, fn c ->
                %{
                  "id" => call_id(),
                  "type" => "function",
                  "function" => %{"name" => c.name, "arguments" => c.arguments}
                }
              end)

          message =
            message
            |> Map.put("content", if(text == "", do: nil, else: text))
            |> Map.put("tool_calls", tool_calls)

          finish =
            if choice["finish_reason"] == "stop", do: "tool_calls", else: choice["finish_reason"]

          choice = %{choice | "message" => message, "finish_reason" => finish}
          %{response | "choices" => [choice]}
        end

      _ ->
        response
    end
  end

  def rewrite_response(response), do: response

  # ── Scanner ───────────────────────────────────────────────

  # Inbound text is held from the moment it could still extend into a
  # marker; everything before that is safe to emit. All markers start with
  # the ASCII "<", so hold boundaries are always UTF-8 character boundaries.
  defp step(%{mode: :done} = state, emitted), do: {Enum.reverse(emitted), %{state | buffer: ""}}

  defp step(%{mode: :text, buffer: buffer} = state, emitted) do
    case earliest(buffer, @anchors) do
      {pos, anchor} ->
        {pre, rest} = split_at(buffer, pos)
        rest = drop_first(rest, byte_size(anchor))
        # The block opener usually follows a blank line; consume it with the
        # marker so the visible text does not keep a trailing "\n\n".
        pre = if anchor in @block_starts, do: drop_last(pre, frame_len(pre)), else: pre
        emitted = if pre == "", do: emitted, else: [{:text, pre} | emitted]

        step(
          %{state | mode: {:block, Map.fetch!(@anchor_dialect, anchor)}, buffer: rest},
          emitted
        )

      nil ->
        {out, rest} = split_at(buffer, byte_size(buffer) - hold_len(buffer, @anchors))
        emitted = if out == "", do: emitted, else: [{:text, out} | emitted]
        {Enum.reverse(emitted), %{state | buffer: rest}}
    end
  end

  defp step(%{mode: {:block, dialect}, buffer: buffer} = state, emitted) do
    buffer = ltrim_ws(buffer)

    cond do
      buffer == "" ->
        {Enum.reverse(emitted), %{state | buffer: ""}}

      match = block_end_at?(buffer) ->
        step(%{state | mode: :done, buffer: drop_first(buffer, byte_size(match))}, emitted)

      partial_marker?(buffer) ->
        # A forming invoke/block-end tag — wait for more text rather than
        # junk-skip it.
        {Enum.reverse(emitted), %{state | buffer: buffer}}

      true ->
        case parse_invoke(buffer, dialect) do
          {:ok, call, rest} ->
            call = Map.put(call, :index, state.calls)
            step(%{state | buffer: rest, calls: state.calls + 1}, [{:tool_call, call} | emitted])

          :incomplete ->
            {Enum.reverse(emitted), %{state | buffer: buffer}}

          :error ->
            step(%{state | buffer: skip_to_marker(buffer)}, emitted)
        end
    end
  end

  # Grammar: invoke_start ws1 name="…" ws0 ">" body invoke_end
  defp parse_invoke(buffer, dialect) do
    open = dialect.invoke_start

    cond do
      String.starts_with?(buffer, open) ->
        with {:ok, tail} <- ws1(drop_first(buffer, byte_size(open))),
             {:ok, name, tail} <- attr(tail, "name"),
             {:ok, tail} <- tag_close(tail) do
          case :binary.match(tail, dialect.invoke_end) do
            :nomatch ->
              :incomplete

            {pos, _len} ->
              body = :binary.part(tail, 0, pos)
              rest = drop_first(tail, pos + byte_size(dialect.invoke_end))
              {:ok, %{name: name, arguments: params_to_json(body, dialect)}, rest}
          end
        else
          other -> other
        end

      String.starts_with?(open, buffer) ->
        :incomplete

      true ->
        :error
    end
  end

  # Grammar: param_start ws1 name="…" ws1 string="true|false" ws0 ">" value param_end.
  # The body is fully buffered (invoke_end was found), so failures are final.
  defp parse_param(body, dialect) do
    with {:ok, tail} <- ws1(drop_first(body, byte_size(dialect.param_start))),
         {:ok, name, tail} <- attr(tail, "name"),
         {:ok, tail} <- ws1(tail),
         {:ok, string?, tail} <- string_attr(tail),
         {:ok, tail} <- tag_close(tail),
         {pos, _len} <- :binary.match(tail, dialect.param_end) do
      value = :binary.part(tail, 0, pos)
      rest = drop_first(tail, pos + byte_size(dialect.param_end))
      {{name, value, string?}, rest}
    else
      _ -> :error
    end
  end

  defp params_to_json(body, dialect) do
    body
    |> collect_params(dialect, [])
    |> Map.new(fn
      {name, raw, true} ->
        {name, raw}

      {name, raw, false} ->
        case Jason.decode(raw) do
          {:ok, value} -> {name, value}
          {:error, _} -> {name, raw}
        end
    end)
    |> Jason.encode!()
  end

  defp collect_params(body, dialect, acc) do
    body = ltrim_ws(body)

    cond do
      body == "" ->
        Enum.reverse(acc)

      String.starts_with?(body, dialect.param_start) ->
        case parse_param(body, dialect) do
          {param, rest} ->
            collect_params(rest, dialect, [param | acc])

          :error ->
            Logger.debug(
              "[dsml] param parse failed on: #{inspect(String.slice(body, 0, 80))} dialect=#{inspect(dialect)}"
            )

            Enum.reverse(acc)
        end

      true ->
        Logger.debug(
          "[dsml] ignoring non-parameter content in invoke body: #{inspect(String.slice(body, 0, 60))}"
        )

        Enum.reverse(acc)
    end
  end

  # ── Token helpers ─────────────────────────────────────────

  defp earliest(buffer, markers) do
    markers
    |> Enum.reduce(nil, fn marker, best ->
      case :binary.match(buffer, marker) do
        :nomatch -> best
        {pos, _} -> if is_nil(best) or pos < elem(best, 0), do: {pos, marker}, else: best
      end
    end)
  end

  defp block_end_at?(buffer), do: Enum.find(@block_ends, &String.starts_with?(buffer, &1))

  # The buffer so far is only a prefix of some invoke/block-end tag.
  defp partial_marker?(buffer) do
    Enum.any?(@invoke_starts ++ @block_ends, fn marker ->
      byte_size(buffer) < byte_size(marker) and String.starts_with?(marker, buffer)
    end)
  end

  # Malformed invoke: skip ahead to the next plausible marker so a later
  # well-formed invoke still converts. A marker at position 0 already failed
  # to parse, so it is dropped as junk. The final branch drops at least one
  # byte so the scan always makes progress.
  defp skip_to_marker(buffer) do
    case earliest(buffer, @invoke_starts ++ @block_ends) do
      {pos, _marker} when pos > 0 ->
        drop_first(buffer, pos)

      {_pos, marker} ->
        drop_first(buffer, byte_size(marker))

      nil ->
        drop_first(
          buffer,
          max(byte_size(buffer) - hold_len(buffer, @invoke_starts ++ @block_ends), 1)
        )
    end
  end

  defp hold_len(buffer, markers) do
    markers
    |> Enum.map(&suffix_prefix_len(buffer, &1))
    |> Enum.max()
  end

  # Longest proper prefix of `marker` that is a suffix of `buffer`. Every
  # prefix of every marker ends on a UTF-8 boundary, so the split it induces
  # is always character-aligned.
  defp suffix_prefix_len(buffer, marker) do
    max = min(byte_size(marker) - 1, byte_size(buffer))
    suffix_prefix_len(buffer, marker, max)
  end

  defp suffix_prefix_len(_buffer, _marker, 0), do: 0

  defp suffix_prefix_len(buffer, marker, len) do
    suffix = binary_part(buffer, byte_size(buffer) - len, len)

    if suffix == binary_part(marker, 0, len) do
      len
    else
      suffix_prefix_len(buffer, marker, len - 1)
    end
  end

  defp frame_len(pre), do: if(String.ends_with?(pre, "\n\n"), do: 2, else: 0)

  defp ltrim_ws(<<c, rest::binary>>) when c in ~c"\t\n\r ", do: ltrim_ws(rest)
  defp ltrim_ws(bin), do: bin

  defp ws1(<<c, rest::binary>>) when c in ~c"\t\n\r ", do: {:ok, ltrim_ws(rest)}
  defp ws1(<<>>), do: :incomplete
  defp ws1(_), do: :error

  defp attr(tail, key) do
    prefix = key <> "=\""

    cond do
      String.starts_with?(tail, prefix) ->
        body = drop_first(tail, byte_size(prefix))

        case :binary.match(body, "\"") do
          :nomatch -> :incomplete
          {pos, _} -> {:ok, :binary.part(body, 0, pos), drop_first(body, pos + 1)}
        end

      String.starts_with?(prefix, tail) ->
        :incomplete

      true ->
        :error
    end
  end

  defp string_attr(tail) do
    case attr(tail, "string") do
      {:ok, "true", rest} -> {:ok, true, rest}
      {:ok, "false", rest} -> {:ok, false, rest}
      {:ok, _, _rest} -> :error
      other -> other
    end
  end

  defp tag_close(tail) do
    case ltrim_ws(tail) do
      ">" <> rest -> {:ok, rest}
      "" -> :incomplete
      _ -> :error
    end
  end

  # ── Byte helpers ──────────────────────────────────────────

  defp split_at(bin, pos), do: :erlang.split_binary(bin, pos)
  defp drop_first(bin, n) when n <= byte_size(bin), do: :binary.part(bin, n, byte_size(bin) - n)
  defp drop_last(bin, n) when n <= byte_size(bin), do: :binary.part(bin, 0, byte_size(bin) - n)
  defp drop_last(bin, _n), do: bin

  defp call_id,
    do:
      "call_" <>
        (:crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false))
end
