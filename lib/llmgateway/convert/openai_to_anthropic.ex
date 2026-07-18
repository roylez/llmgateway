defmodule Llmgateway.Convert.OpenAIToAnthropic do
  @moduledoc """
  Converts OpenAI chat/completions request bodies to Anthropic messages format.

  Returns `{converted_body, warnings}` — warnings lists unsupported params that were dropped.
  """

  @unsupported_params ~w(presence_penalty frequency_penalty logprobs top_logprobs logit_bias seed)

  @reasoning_budgets %{
    "low" => 1_024,
    "medium" => 2_048,
    "high" => 4_096
  }

  @doc """
  Convert an OpenAI chat/completions request body to Anthropic messages API format.
  """
  def convert_request(body) when is_map(body) do
    {system, messages} = extract_system(body["messages"] || [])
    {tools, tool_choice} = convert_tools(body["tools"], body["tool_choice"])
    {thinking, reasoning_warnings} = convert_reasoning(body["reasoning_effort"])
    dropped_warnings = dropped_params(body)

    max_tokens = body["max_tokens"] || body["max_completion_tokens"] || default_max_tokens(thinking)

    result =
      %{"messages" => messages, "max_tokens" => max_tokens}
      |> maybe_put("system", system)
      |> maybe_put("temperature", clamp_temperature(body["temperature"]))
      |> maybe_put("top_p", body["top_p"])
      |> maybe_put("stop_sequences", body["stop"])
      |> maybe_put("stream", body["stream"])
      |> maybe_put("tools", tools)
      |> maybe_put("tool_choice", tool_choice)
      |> maybe_put("thinking", thinking)
      |> maybe_put("metadata", convert_metadata(body["user"]))

    {result, reasoning_warnings ++ dropped_warnings}
  end

  # ── System message extraction ─────────────────────────────

  defp extract_system(messages) do
    {system_msgs, rest} =
      Enum.split_while(messages, fn
        %{"role" => "system"} -> true
        _ -> false
      end)

    system =
      case system_msgs do
        [] -> nil
        msgs -> msgs |> Enum.map_join("\n", & &1["content"])
      end

    # Also extract any system messages that appear later in the conversation
    {later_system, non_system} =
      Enum.split_with(rest, fn
        %{"role" => "system"} -> true
        _ -> false
      end)

    combined_system =
      case {system, later_system} do
        {nil, []} -> nil
        {s, []} -> s
        {nil, msgs} -> msgs |> Enum.map_join("\n", & &1["content"])
        {s, msgs} -> s <> "\n" <> Enum.map_join(msgs, "\n", & &1["content"])
      end

    converted_messages = Enum.map(non_system, &convert_message/1)
    {combined_system, converted_messages}
  end

  # ── Message conversion ────────────────────────────────────

  defp convert_message(%{"role" => "user", "content" => content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp convert_message(%{"role" => "user", "content" => parts}) when is_list(parts) do
    %{"role" => "user", "content" => Enum.map(parts, &convert_content_part/1)}
  end

  defp convert_message(%{"role" => "assistant", "content" => content, "tool_calls" => tool_calls})
       when is_list(tool_calls) do
    content_blocks =
      (if content, do: [%{"type" => "text", "text" => content}], else: []) ++
        Enum.map(tool_calls, &openai_tool_call_to_anthropic/1)

    %{"role" => "assistant", "content" => content_blocks}
  end

  defp convert_message(%{"role" => "assistant", "content" => content}) when is_binary(content) do
    %{"role" => "assistant", "content" => content}
  end

  defp convert_message(%{"role" => "tool", "tool_call_id" => id, "content" => content}) do
    %{
      "role" => "user",
      "content" => [
        %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
      ]
    }
  end

  defp convert_message(msg), do: msg

  # ── Content part conversion (multimodal) ──────────────────

  defp convert_content_part(%{"type" => "text", "text" => text}) do
    %{"type" => "text", "text" => text}
  end

  defp convert_content_part(%{"type" => "image_url", "image_url" => %{"url" => url}}) do
    case parse_data_url(url) do
      {:ok, media_type, data} ->
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
        }

      :error ->
        %{
          "type" => "image",
          "source" => %{"type" => "url", "url" => url}
        }
    end
  end

  defp convert_content_part(part), do: part

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] -> {:ok, media_type, data}
      _ -> :error
    end
  end

  defp parse_data_url(_), do: :error

  # ── Tool conversion ───────────────────────────────────────

  defp convert_tools(nil, _), do: {nil, nil}
  defp convert_tools([], _), do: {nil, nil}

  defp convert_tools(tools, tool_choice) when is_list(tools) do
    converted = Enum.map(tools, &convert_tool_def/1)
    choice = convert_tool_choice(tool_choice)
    {converted, choice}
  end

  defp convert_tool_def(%{"type" => "function", "function" => func}) do
    %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{"type" => "object", "properties" => %{}}
    }
  end

  defp convert_tool_def(tool), do: tool

  defp convert_tool_choice(nil), do: nil
  defp convert_tool_choice("auto"), do: %{"type" => "auto"}
  defp convert_tool_choice("none"), do: nil
  defp convert_tool_choice("required"), do: %{"type" => "any"}

  defp convert_tool_choice(%{"type" => "function", "function" => %{"name" => name}}) do
    %{"type" => "tool", "name" => name}
  end

  defp convert_tool_choice(choice), do: choice

  defp openai_tool_call_to_anthropic(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    input =
      case Jason.decode(args) do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  # ── Reasoning effort → thinking budget ────────────────────

  defp convert_reasoning(nil), do: {nil, []}

  defp convert_reasoning(effort) when is_binary(effort) do
    case @reasoning_budgets[effort] do
      nil ->
        {nil, [{:warning, "unknown reasoning_effort '#{effort}', dropped"}]}

      budget ->
        {%{"type" => "enabled", "budget_tokens" => budget}, []}
    end
  end

  defp convert_reasoning(_), do: {nil, []}

  defp default_max_tokens(%{"type" => "enabled"}), do: 16_384
  defp default_max_tokens(_), do: 4_096

  # ── Metadata ──────────────────────────────────────────────

  defp convert_metadata(nil), do: nil
  defp convert_metadata(user_id), do: %{"user_id" => user_id}

  # ── Temperature clamping ──────────────────────────────────

  defp clamp_temperature(nil), do: nil
  defp clamp_temperature(t) when is_number(t), do: min(t, 1.0)

  # ── Unsupported parameter detection ───────────────────────

  defp dropped_params(body) do
    @unsupported_params
    |> Enum.filter(&Map.has_key?(body, &1))
    |> Enum.map(&{:dropped, "#{&1} not supported by Anthropic"})
  end

  # ── Helpers ───────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
