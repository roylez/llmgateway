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
end
