defmodule Llmgateway.FallbackStreamTest.Executor do
  def call(deployment, body, opts) do
    identity = {deployment.provider_name, deployment.upstream_model}
    send(self(), {:stream_call, identity, body, opts})
    Process.get(:stream_results) |> Map.fetch!(identity)
  end
end

defmodule Llmgateway.FallbackStreamTest do
  use ExUnit.Case

  alias Llmgateway.{Config, Cooldown, Fallback, Router}

  @fixtures_path "test/fixtures"

  setup do
    start_supervised!({Cooldown, window_ms: 60_000})
    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    {:ok, _pid} = Router.start_link(config)
    :ok
  end

  test "retries a same-name deployment before the named fallback" do
    body = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    Process.put(:stream_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} =>
        {:error, %{type: :server_error, message: "down"}},
      {"openai-main", "gpt-4o-mini"} => {:ok, [:sibling_stream]}
    })

    assert {:ok, [:sibling_stream], deployment} =
             Fallback.stream("deepseek-v4-flash", body,
               key: "personal-key",
               rid: "request-1",
               timeout: 4_000,
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert Cooldown.active?("openrouter-personal", "deepseek/deepseek-chat")

    assert {deployment.provider_name, deployment.upstream_model} ==
             {"openai-main", "gpt-4o-mini"}

    assert_receive {:stream_call, {"openrouter-personal", "deepseek/deepseek-chat"}, ^body,
                    primary_opts}

    assert primary_opts[:rid] == "request-1"
    assert primary_opts[:timeout] == 4_000

    assert_receive {:stream_call, {"openai-main", "gpt-4o-mini"}, ^body, sibling_opts}
    assert sibling_opts[:rid] == "request-1"
    assert sibling_opts[:timeout] == 4_000
  end

  test "does not cool down a provider on client errors" do
    Process.put(:stream_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} =>
        {:error, %{type: :client_error, status: 404}},
      {"openai-main", "gpt-4o-mini"} => {:ok, [:sibling_stream]}
    })

    assert {:ok, [:sibling_stream], %{provider_name: "openai-main"}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "personal-key",
               rid: "request-1",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    refute Cooldown.active?("openrouter-personal", "deepseek/deepseek-chat")
    drain_mailbox()

    Process.put(:stream_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} => {:ok, [:primary_stream]}
    })

    assert {:ok, [:primary_stream], %{provider_name: "openrouter-personal"}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "personal-key",
               rid: "request-2",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert_receive {:stream_call, {"openrouter-personal", "deepseek/deepseek-chat"}, %{}, _}
    refute_received {:stream_call, {"openai-main", "gpt-4o-mini"}, _, _}
  end

  test "skips a cooling candidate and tries its sibling" do
    Cooldown.record_failure("openrouter-personal", "deepseek/deepseek-chat")

    Process.put(:stream_results, %{
      {"openai-main", "gpt-4o-mini"} => {:ok, [:sibling_stream]}
    })

    assert {:ok, [:sibling_stream], %{provider_name: "openai-main"}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "personal-key",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert_receive {:stream_call, {"openai-main", "gpt-4o-mini"}, %{}, _}
    refute_received {:stream_call, {"openrouter-personal", "deepseek/deepseek-chat"}, _, _}
  end

  test "stops after a non-retryable provider failure" do
    Process.put(:stream_results, %{
      {"openrouter-personal", "deepseek/deepseek-chat"} =>
        {:error, %{type: :unknown_error, message: "bad request"}}
    })

    assert {:error, %{type: :unknown_error, message: "bad request"}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "personal-key",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert_receive {:stream_call, {"openrouter-personal", "deepseek/deepseek-chat"}, %{}, _}
    refute_received {:stream_call, _, _, _}
  end

  test "expands same-name candidates at each fallback position" do
    GenServer.stop(Router)

    config = %{
      "providers" => [
        %{name: "primary-a", api_key: nil, base_url: "https://example.test"},
        %{name: "primary-b", api_key: nil, base_url: "https://example.test"},
        %{name: "secondary-a", api_key: nil, base_url: "https://example.test"},
        %{name: "secondary-b", api_key: nil, base_url: "https://example.test"},
        %{name: "tertiary-a", api_key: nil, base_url: "https://example.test"}
      ],
      "models" => [
        model("primary", "primary-a", "primary-a-model", 10),
        model("primary", "primary-b", "primary-b-model", 0),
        model("secondary", "secondary-a", "secondary-a-model", 10),
        model("secondary", "secondary-b", "secondary-b-model", 0),
        model("tertiary", "tertiary-a", "tertiary-a-model", 0)
      ],
      "keys" => [],
      "fallbacks" => %{
        "primary" => ["secondary"],
        "secondary" => ["primary", "tertiary"]
      }
    }

    {:ok, _pid} = Router.start_link(config)

    Process.put(:stream_results, %{
      {"primary-a", "primary-a-model"} => {:error, %{type: :server_error}},
      {"primary-b", "primary-b-model"} => {:error, %{type: :transport_error}},
      {"secondary-a", "secondary-a-model"} => {:error, %{type: :server_error}},
      {"secondary-b", "secondary-b-model"} => {:error, %{type: :transport_error}},
      {"tertiary-a", "tertiary-a-model"} => {:ok, [:tertiary_stream]}
    })

    assert {:ok, [:tertiary_stream], %{name: "tertiary"}} =
             Fallback.stream("primary", %{}, executor: Llmgateway.FallbackStreamTest.Executor)

    assert_receive {:stream_call, {"primary-a", "primary-a-model"}, %{}, _}
    assert_receive {:stream_call, {"primary-b", "primary-b-model"}, %{}, _}
    assert_receive {:stream_call, {"secondary-a", "secondary-a-model"}, %{}, _}
    assert_receive {:stream_call, {"secondary-b", "secondary-b-model"}, %{}, _}
    assert_receive {:stream_call, {"tertiary-a", "tertiary-a-model"}, %{}, _}
    refute_received {:stream_call, _, _, _}
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp model(name, provider_name, upstream_model, priority) do
    %{
      name: name,
      provider_name: provider_name,
      provider_type: :openai,
      upstream_model: upstream_model,
      priority: priority,
      context: 1,
      output_limit: 1,
      path: "/chat/completions",
      keys: nil
    }
  end
end
