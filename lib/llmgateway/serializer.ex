defmodule Llmgateway.Serializer do
  @moduledoc """
  Serialization of canonical model records into OpenAI- and LiteLLM-compatible
  discovery payloads.

  OMP's LiteLLM provider reads the standard LiteLLM schema from /model/info:
  supports_reasoning, supports_vision, supports_function_calling,
  supported_openai_params, and max_input_tokens / max_output_tokens. Derive
  those from the canonical LLMDB capabilities so aliases present identically to
  their backing models.
  """

  def serialize_litellm_model_info(m) do
    limits = m.limits || %{}
    context = limits[:context]
    output = limits[:output]
    reasoning = reasoning_enabled?(m.capabilities)
    supported_params = supported_openai_params(m)

    model_info =
      %{
        "id" => m.id,
        "max_input_tokens" => context,
        "max_output_tokens" => output,
        "max_tokens" => output,
        "supports_reasoning" => reasoning,
        "supports_vision" => vision_supported?(m.modalities),
        "supports_function_calling" => function_calling_supported?(m.capabilities)
      }
      |> maybe_put("supported_openai_params", supported_params)

    %{
      "model_name" => m.id,
      "model_info" => model_info
    }
  end

  def serialize_model(m) do
    limits = m.limits || %{}

    %{
      "id" => m.id,
      "object" => "model",
      "created" => 0,
      "owned_by" => m.owned_by,
      "limits" => limits,
      "context_window" => limits[:context],
      "max_tokens" => limits[:output],
      "capabilities" => m.capabilities,
      "modalities" => m.modalities,
      "execution" => m.execution,
      "extra" => m.extra,
      "reasoning" => reasoning_enabled?(m.capabilities)
    }
    |> maybe_put("thinking", thinking_projection(m.extra))
  end

  defp reasoning_enabled?(%{reasoning: %{enabled: true}}), do: true
  defp reasoning_enabled?(_), do: false

  defp vision_supported?(%{input: input}) when is_list(input), do: :image in input
  defp vision_supported?(_), do: false

  defp function_calling_supported?(%{tools: %{enabled: true}}), do: true
  defp function_calling_supported?(_), do: false

  defp supported_openai_params(m) do
    params =
      []
      |> then(
        &if function_calling_supported?(m.capabilities),
          do: ["tools", "tool_choice" | &1],
          else: &1
      )
      |> then(&if reasoning_enabled?(m.capabilities), do: ["reasoning_effort" | &1], else: &1)

    case params do
      [] -> nil
      _ -> Enum.reverse(params)
    end
  end

  defp thinking_projection(extra) when is_map(extra) do
    extra
    |> Map.get("reasoning_options", [])
    |> Enum.find_value(fn
      %{"type" => "effort", "values" => values} when is_list(values) ->
        %{mode: "effort", efforts: values -- ["none"]}

      _ ->
        nil
    end)
  end

  defp thinking_projection(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
