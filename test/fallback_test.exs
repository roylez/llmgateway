defmodule Llmgateway.FallbackTest.Executor do
  def call(deployment, body, opts) do
    identity = {deployment.provider_name, deployment.upstream_model}
    send(self(), {:call, identity, body, opts})
    Process.get(:call_results) |> Map.fetch!(identity)
  end
end

defmodule Llmgateway.FallbackTest do
  use ExUnit.Case

  alias Llmgateway.{Config, Fallback, Router}

  @fixtures_path "test/fixtures"

  setup do
    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    {:ok, _pid} = Router.start_link(config)
    :ok
  end

  test "retries a same-name candidate and annotates the response" do
    body = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    Process.put(:call_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} =>
        {:error, %{type: :server_error, message: "down"}},
      {"openai-main", "gpt-4o-mini"} => {:ok, %{"id" => "response"}}
    })

    assert {:ok, deployments, fallbacks} =
             Router.resolve_deployments("deepseek-v4-flash", key: "personal-key")

    assert {:ok, response} =
             Fallback.call_with_fallback(deployments, fallbacks, body,
               executor: Llmgateway.FallbackTest.Executor
             )

    assert_receive {:call, {"openrouter-personal", "deepseek/deepseek-chat"}, ^body, _}
    assert_receive {:call, {"openai-main", "gpt-4o-mini"}, ^body, _}
    assert response["_llmgateway"]["fallback_from"] == "deepseek-v4-flash"
    assert response["_llmgateway"]["fallback_depth"] == 1
  end

  test "stops after a non-retryable candidate error" do
    Process.put(:call_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} =>
        {:error, %{type: :unknown_error, message: "bad request"}}
    })

    assert {:ok, deployments, fallbacks} =
             Router.resolve_deployments("deepseek-v4-flash", key: "personal-key")

    assert {:error, %{type: :unknown_error, message: "bad request"}} =
             Fallback.call_with_fallback(deployments, fallbacks, %{},
               executor: Llmgateway.FallbackTest.Executor
             )

    assert_receive {:call, {"openrouter-personal", "deepseek/deepseek-chat"}, %{}, _}
    refute_received {:call, _, _, _}
  end
end
