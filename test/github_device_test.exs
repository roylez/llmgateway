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
  end
end
