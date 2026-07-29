defmodule Llmgateway.Convert.InboundAnthropic do
  @moduledoc """
  Converts inbound Anthropic messages API requests to the canonical OpenAI format,
  and converts OpenAI responses back to Anthropic format for the client.

  This is the reverse of the provider-side conversion — here the CLIENT speaks
  Anthropic and the proxy normalizes to OpenAI internally.
  """

  @finish_reason_map %{
    "stop" => "end_turn",
    "length" => "max_tokens",
    "tool_calls" => "tool_use"
  }

  # ── Inbound: Anthropic request → OpenAI canonical ─────────

  @doc """
  Convert an Anthropic messages request body to OpenAI chat/completions format.
  """
  def to_canonical(body) when is_map(body) do
    messages = build_messages(body["system"], body["messages"] || [])
    {tools, tool_choice} = convert_tools(body["tools"], body["tool_choice"])

    result =
      %{
        "model" => body["model"],
        "messages" => messages
      }
      |> maybe_put("max_tokens", body["max_tokens"])
      |> maybe_put("temperature", body["temperature"])
      |> maybe_put("top_p", body["top_p"])
      |> maybe_put("stop", body["stop_sequences"])
      |> maybe_put("stream", body["stream"])
      |> maybe_put("tools", tools)
      |> maybe_put("tool_choice", tool_choice)
      |> maybe_put_thinking(body["thinking"])
      |> maybe_put("user", get_in(body, ["metadata", "user_id"]))

    result
  end

  # ── Outbound: OpenAI response → Anthropic format ──────────

  @doc """
  Convert an OpenAI chat/completions response to Anthropic messages format.
  """
  def from_canonical(body) when is_map(body) do
    choice = List.first(body["choices"] || []) || %{}
    message = choice["message"] || %{}
    content_blocks = build_content_blocks(message)
    stop_reason = Map.get(@finish_reason_map, choice["finish_reason"], "end_turn")

    usage = convert_usage(body["usage"])

    result =
      %{
        "id" => body["id"] || "msg_#{random_id()}",
        "type" => "message",
        "role" => "assistant",
        "model" => body["model"],
        "content" => content_blocks,
        "stop_reason" => stop_reason,
        "stop_sequence" => nil,
        "usage" => usage
      }

    # Preserve _llmgateway metadata if present
    case body["_llmgateway"] do
      nil -> result
      meta -> Map.put(result, "_llmgateway", meta)
    end
  end

  @doc """
  Convert an OpenAI SSE chunk to Anthropic SSE event format.

  Returns `{:ok, [events]}` — may return multiple events for a single chunk.
  Returns `:done` for the final event.
  """
  def chunk_to_anthropic_events(chunk, state \\ %{}) do
    choices = chunk["choices"] || []
    choice = List.first(choices) || %{}
    delta = choice["delta"] || %{}
    finish_reason = choice["finish_reason"]
    started = state[:started] || false
    thinking_open = state[:thinking_open] || false
    text_open = state[:text_open] || false
    next_idx = state[:next_idx] || 0
    open_tool_ath_idx = state[:open_tool_ath_idx]
    tool_index_map = state[:tool_index_map] || %{}

    events = []

    # Emit message_start only on first chunk — NO eager blocks
    {events, started} =
      if not started and delta["role"] do
        msg_start = %{
          "type" => "message_start",
          "message" => %{
            "id" => chunk["id"] || "msg_#{random_id()}",
            "type" => "message",
            "role" => "assistant",
            "model" => chunk["model"],
            "content" => [],
            "stop_reason" => nil,
            "stop_sequence" => nil,
            "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
          }
        }

        {events ++ [msg_start], true}
      else
        {events, started}
      end

    # Reasoning/thinking content — lazily open thinking block on first reasoning
    # Supports both "reasoning_content" (OpenAI) and bare "reasoning" (deepseek etc.)
    reasoning = delta["reasoning_content"] || delta["reasoning"]

    {events, thinking_open, next_idx, open_tool_ath_idx} =
      if reasoning && reasoning != "" do
        # Close any open tool block before switching to thinking
        {events, open_tool_ath_idx} =
          if open_tool_ath_idx != nil do
            {events ++ [%{"type" => "content_block_stop", "index" => open_tool_ath_idx}], nil}
          else
            {events, open_tool_ath_idx}
          end

        {events, thinking_open, next_idx} =
          if not thinking_open do
            block_start = %{
              "type" => "content_block_start",
              "index" => next_idx,
              "content_block" => %{"type" => "thinking", "thinking" => ""}
            }

            {events ++ [block_start], true, next_idx + 1}
          else
            {events, thinking_open, next_idx}
          end

        thinking_idx = next_idx - 1

        thinking_delta = %{
          "type" => "content_block_delta",
          "index" => thinking_idx,
          "delta" => %{"type" => "thinking_delta", "thinking" => reasoning}
        }

        {events ++ [thinking_delta], thinking_open, next_idx, open_tool_ath_idx}
      else
        {events, thinking_open, next_idx, open_tool_ath_idx}
      end

    # Text content delta — lazily open text block on first content
    {events, thinking_open, text_open, next_idx} =
      if delta["content"] && delta["content"] != "" do
        # Close thinking block if open (thinking always precedes text)
        {events, thinking_open} =
          if thinking_open do
            thinking_stop_idx = next_idx - 1
            {events ++ [%{"type" => "content_block_stop", "index" => thinking_stop_idx}], false}
          else
            {events, thinking_open}
          end

        {events, text_open, next_idx} =
          if not text_open do
            block_start = %{
              "type" => "content_block_start",
              "index" => next_idx,
              "content_block" => %{"type" => "text", "text" => ""}
            }

            {events ++ [block_start], true, next_idx + 1}
          else
            {events, text_open, next_idx}
          end

        text_idx = next_idx - 1

        text_delta = %{
          "type" => "content_block_delta",
          "index" => text_idx,
          "delta" => %{"type" => "text_delta", "text" => delta["content"]}
        }

        {events ++ [text_delta], thinking_open, text_open, next_idx}
      else
        {events, thinking_open, text_open, next_idx}
      end

    # Tool call deltas
    {events, thinking_open, text_open, next_idx, open_tool_ath_idx, tool_index_map} =
      if delta["tool_calls"] do
        # Close thinking block if open before switching to tool
        {events, thinking_open} =
          if thinking_open do
            thinking_stop_idx = next_idx - 1
            {events ++ [%{"type" => "content_block_stop", "index" => thinking_stop_idx}], false}
          else
            {events, thinking_open}
          end

        {events, text_open, next_idx, open_tool_ath_idx, tool_index_map} =
          Enum.reduce(delta["tool_calls"], {events, text_open, next_idx, open_tool_ath_idx, tool_index_map}, fn tc, {evts, t_open, n_idx, o_tool_ath, t_map} ->
            oa_idx = tc["index"]

            if tc["id"] do
              # New tool call — close preceding blocks if open
              evts =
                if t_open do
                  text_stop_idx = n_idx - 1
                  evts ++ [%{"type" => "content_block_stop", "index" => text_stop_idx}]
                else
                  evts
                end

              {evts, _o_tool_ath} =
                case o_tool_ath do
                  nil -> {evts, nil}
                  idx -> {evts ++ [%{"type" => "content_block_stop", "index" => idx}], nil}
                end
              ath_idx = n_idx

              block_start = %{
                "type" => "content_block_start",
                "index" => ath_idx,
                "content_block" => %{
                  "type" => "tool_use",
                  "id" => tc["id"],
                  "name" => get_in(tc, ["function", "name"]) || "",
                  "input" => %{}
                }
              }

              t_map = Map.put(t_map, oa_idx, ath_idx)

              # If arguments came in the same chunk, emit them as a delta
              args = sanitize_args(get_in(tc, ["function", "arguments"]) || "")
              events = if args != "", do: evts ++ [block_start, %{"type" => "content_block_delta", "index" => ath_idx, "delta" => %{"type" => "input_json_delta", "partial_json" => args}}], else: evts ++ [block_start]

              {events, false, n_idx + 1, ath_idx, t_map}
            else
              # Argument delta for existing tool
              args = sanitize_args(get_in(tc, ["function", "arguments"]) || "")
              ath_idx = Map.get(t_map, oa_idx, oa_idx)

              arg_delta = %{
                "type" => "content_block_delta",
                "index" => ath_idx,
                "delta" => %{"type" => "input_json_delta", "partial_json" => args}
              }

              {evts ++ [arg_delta], t_open, n_idx, o_tool_ath, t_map}
            end
          end)

        {events, thinking_open, text_open, next_idx, open_tool_ath_idx, tool_index_map}
      else
        {events, thinking_open, text_open, next_idx, open_tool_ath_idx, tool_index_map}
      end

    # Finish reason → close open block, then message_delta + message_stop
    finished = state[:finished] || false

    {events, finished} =
      if finish_reason && not finished do
        stop_reason = Map.get(@finish_reason_map, finish_reason, "end_turn")

        # Close whatever block is currently open
        events =
          cond do
            text_open ->
              events ++ [%{"type" => "content_block_stop", "index" => next_idx - 1}]

            open_tool_ath_idx != nil ->
              events ++ [%{"type" => "content_block_stop", "index" => open_tool_ath_idx}]

            thinking_open ->
              events ++ [%{"type" => "content_block_stop", "index" => next_idx - 1}]

            true ->
              events
          end

        usage_event = %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => stop_reason, "stop_sequence" => nil},
          "usage" => convert_usage(chunk["usage"])
        }

        {events ++ [usage_event, %{"type" => "message_stop"}], true}
      else
        {events, finished}
      end

    new_state =
      state
      |> Map.put(:started, started)
      |> Map.put(:finished, finished || finish_reason != nil)
      |> Map.put(:thinking_open, thinking_open)
      |> Map.put(:text_open, text_open)
      |> Map.put(:next_idx, next_idx)
      |> Map.put(:open_tool_ath_idx, open_tool_ath_idx)
      |> Map.put(:tool_index_map, tool_index_map)

    if events == [], do: {:skip, new_state}, else: {:ok, events, new_state}
  end

  # ── Message building ──────────────────────────────────────

  defp build_messages(nil, messages), do: convert_messages(messages)
  defp build_messages("", messages), do: convert_messages(messages)

  defp build_messages(system, messages) when is_binary(system) do
    [%{"role" => "system", "content" => system} | convert_messages(messages)]
  end

  defp build_messages(system, messages) when is_list(system) do
    # Anthropic supports system as list of content blocks
    text = system |> Enum.map_join("\n", & &1["text"])
    [%{"role" => "system", "content" => text} | convert_messages(messages)]
  end

  defp convert_messages(messages) do
    Enum.flat_map(messages, fn msg ->
      case convert_message(msg) do
        list when is_list(list) -> list
        single -> [single]
      end
    end)
  end

  defp convert_message(%{"role" => "user", "content" => content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp convert_message(%{"role" => "user", "content" => parts}) when is_list(parts) do
    # Check for tool_result blocks — these become separate tool messages
    {tool_results, other_parts} =
      Enum.split_with(parts, fn
        %{"type" => "tool_result"} -> true
        _ -> false
      end)

    user_messages =
      if other_parts != [] do
        converted = Enum.map(other_parts, &convert_content_part/1)
        [%{"role" => "user", "content" => converted}]
      else
        []
      end

    tool_messages =
      Enum.map(tool_results, fn tr ->
        %{
          "role" => "tool",
          "tool_call_id" => tr["tool_use_id"],
          "content" => tr["content"] || ""
        }
      end)

    # Return flattened — caller needs to handle this
    case user_messages ++ tool_messages do
      [single] -> single
      multiple -> multiple
    end
  end

  defp convert_message(%{"role" => "assistant", "content" => parts}) when is_list(parts) do
    {texts, tool_uses} =
      Enum.reduce(parts, {[], []}, fn
        %{"type" => "text", "text" => t}, {ts, tus} -> {[t | ts], tus}
        %{"type" => "tool_use"} = tu, {ts, tus} -> {ts, [tu | tus]}
        _, acc -> acc
      end)

    text = texts |> Enum.reverse() |> Enum.join("")

    tool_calls =
      tool_uses
      |> Enum.reverse()
      |> Enum.map(fn tu ->
        %{
          "id" => tu["id"],
          "type" => "function",
          "function" => %{
            "name" => tu["name"],
            "arguments" => Jason.encode!(tu["input"] || %{})
          }
        }
      end)

    msg = %{"role" => "assistant"}
    msg = if text != "", do: Map.put(msg, "content", text), else: msg
    msg = if tool_calls != [], do: Map.put(msg, "tool_calls", tool_calls), else: msg
    msg
  end

  defp convert_message(%{"role" => "assistant", "content" => content}) when is_binary(content) do
    %{"role" => "assistant", "content" => content}
  end

  defp convert_message(msg), do: msg

  # ── Content part conversion ───────────────────────────────

  defp convert_content_part(%{"type" => "text", "text" => text}) do
    %{"type" => "text", "text" => text}
  end

  defp convert_content_part(%{"type" => "image", "source" => %{"type" => "base64"} = src}) do
    %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{src["media_type"]};base64,#{src["data"]}"}
    }
  end

  defp convert_content_part(%{"type" => "image", "source" => %{"type" => "url", "url" => url}}) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp convert_content_part(part), do: part

  # ── Content block building (response) ─────────────────────

  defp build_content_blocks(message) do
    text_blocks =
      case message["content"] do
        nil -> []
        "" -> []
        text when is_binary(text) -> [%{"type" => "text", "text" => text}]
      end

    tool_blocks =
      case message["tool_calls"] do
        nil ->
          []

        calls ->
          Enum.map(calls, fn tc ->
            input =
              case Jason.decode(tc["function"]["arguments"] || "{}") do
                {:ok, parsed} -> parsed
                _ -> %{}
              end

            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => tc["function"]["name"],
              "input" => input
            }
          end)
      end

    text_blocks ++ tool_blocks
  end

  # ── Tool conversion ───────────────────────────────────────

  defp convert_tools(nil, _), do: {nil, nil}
  defp convert_tools([], _), do: {nil, nil}

  defp convert_tools(tools, tool_choice) when is_list(tools) do
    converted =
      Enum.map(tools, fn t ->
        %{
          "type" => "function",
          "function" => %{
            "name" => t["name"],
            "description" => t["description"] || "",
            "parameters" => t["input_schema"] || %{"type" => "object", "properties" => %{}}
          }
        }
      end)

    choice = convert_tool_choice(tool_choice)
    {converted, choice}
  end

  defp convert_tool_choice(nil), do: nil
  defp convert_tool_choice(%{"type" => "auto"}), do: "auto"
  defp convert_tool_choice(%{"type" => "any"}), do: "required"

  defp convert_tool_choice(%{"type" => "tool", "name" => name}),
    do: %{"type" => "function", "function" => %{"name" => name}}

  defp convert_tool_choice(choice), do: choice

  # ── Thinking → reasoning_effort ───────────────────────────

  defp maybe_put_thinking(map, nil), do: map

  defp maybe_put_thinking(map, %{"type" => "enabled", "budget_tokens" => budget}) do
    effort =
      cond do
        budget <= 1_024 -> "low"
        budget <= 2_048 -> "medium"
        true -> "high"
      end

    Map.put(map, "reasoning_effort", effort)
  end

  defp maybe_put_thinking(map, _), do: map

  # ── Usage conversion ──────────────────────────────────────

  defp convert_usage(nil), do: %{"input_tokens" => 0, "output_tokens" => 0}

  defp convert_usage(usage) do
    result = %{
      "input_tokens" => usage["prompt_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || 0
    }

    details = usage["prompt_tokens_details"]

    if details do
      result
      |> maybe_put("cache_read_input_tokens", details["cached_tokens"])
      |> maybe_put("cache_creation_input_tokens", details["cache_creation_tokens"])
    else
      result
    end
  end

  # ── Helpers ───────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Strip trailing non-JSON junk from tool arguments.
  # Some models append spurious characters (e.g. "." or control chars)
  # after the closing brace/bracket.
  def sanitize_args(args) do
    args = String.trim_trailing(args)
    # If string ends with } or ] followed by junk, trim to the last } or ]
    case Regex.run(~r/(\}|\])[^}\]]*$/, args) do
      [full, closer] -> String.slice(args, 0, String.length(args) - String.length(full)) <> closer
      _ -> args
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
