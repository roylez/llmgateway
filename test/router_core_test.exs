defmodule Llmgateway.Router.CoreTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Router.Core

  @live %{
    context: 200_000,
    output: 32_000,
    capabilities: %{tools: %{enabled: true}},
    modalities: %{input: [:text, :image], output: [:text]},
    reasoning: %{enabled: true}
  }

  defp copilot_state(metadata) do
    Core.build_state(%{
      "providers" => [%{name: "copilot-main", type: :github_copilot, api_key: nil}],
      "models" => [
        %{
          name: "new-model",
          provider_name: "copilot-main",
          provider_type: :github_copilot,
          upstream_model: "new-model",
          keys: nil,
          priority: 0,
          context: nil,
          output_limit: nil,
          path: "/chat/completions",
          metadata: metadata
        }
      ],
      "keys" => [],
      "fallbacks" => %{}
    })
    |> Core.put_live_limits("copilot-main", %{"new-model" => @live})
  end

  defp listed(state) do
    [model] = Core.list_models(nil, state)
    model
  end

  test "metadata-nil Copilot model advertises live tools, vision, and reasoning" do
    model = listed(copilot_state(nil))

    assert model.limits == %{context: 200_000, output: 32_000}
    assert model.capabilities == %{tools: %{enabled: true}}
    assert model.modalities == %{input: [:text, :image], output: [:text]}

    assert model.extra == %{
             "reasoning_options" => [%{"type" => "effort", "values" => ["low", "medium", "high"]}]
           }
  end

  test "packaged capabilities, modalities, and reasoning win over live data" do
    packaged = %{
      limits: %{context: 1_000, output: 100},
      capabilities: %{tools: %{enabled: false}},
      modalities: %{input: [:text], output: [:text]},
      extra: %{
        "reasoning_options" => [%{"type" => "effort", "values" => ["minimal", "high"]}]
      }
    }

    model = listed(copilot_state(packaged))

    assert model.capabilities == %{tools: %{enabled: false}}
    assert model.modalities == %{input: [:text], output: [:text]}
    assert model.extra == packaged.extra
  end
end
