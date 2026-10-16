defmodule Llmgateway.Auth.GitHubDeviceTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Auth.GitHubDevice

  describe "select_endpoint/1" do
    test "never picks a websocket endpoint" do
      assert GitHubDevice.select_endpoint(["/responses", "ws:/responses"]) == "/responses"
      assert GitHubDevice.select_endpoint(["ws:/responses", "/responses"]) == "/responses"
    end

    test "defaults to /chat/completions when no endpoints are known" do
      assert GitHubDevice.select_endpoint([]) == "/chat/completions"
    end
  end

  describe "parse_model_metadata/1" do
    test "reads limits from the Copilot capabilities object" do
      model = %{
        "id" => "kimi-k3",
        "capabilities" => %{
          "limits" => %{
            "max_context_window_tokens" => 1_048_576,
            "max_output_tokens" => 131_072
          }
        }
      }

      assert GitHubDevice.parse_model_metadata(model) == %{context: 1_048_576, output: 131_072}
    end

    test "returns nil when the response omits limits" do
      assert GitHubDevice.parse_model_metadata(%{"id" => "unknown"}) == nil
    end

    test "reads tools, vision, and reasoning from supports" do
      model = %{
        "capabilities" => %{
          "limits" => %{"max_context_window_tokens" => 8_000},
          "supports" => %{
            "tool_calls" => true,
            "vision" => true,
            "reasoning_effort" => ["low", "high"]
          }
        }
      }

      assert GitHubDevice.parse_model_metadata(model) == %{
               context: 8_000,
               output: nil,
               capabilities: %{tools: %{enabled: true}},
               modalities: %{input: [:text, :image], output: [:text]},
               reasoning: %{enabled: true}
             }
    end

    test "a boolean reasoning_effort does not enable reasoning" do
      model = %{"capabilities" => %{"supports" => %{"reasoning_effort" => true}}}

      assert GitHubDevice.parse_model_metadata(model) == nil
    end

    test "an empty reasoning_effort list does not enable reasoning" do
      model = %{"capabilities" => %{"supports" => %{"reasoning_effort" => []}}}

      assert GitHubDevice.parse_model_metadata(model) == nil
    end
  end
end
