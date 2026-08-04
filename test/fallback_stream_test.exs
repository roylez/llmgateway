defmodule Llmgateway.FallbackStreamTest.Executor do
  def call(deployment, body, opts) do
    send(self(), {:stream_call, deployment.name, body, opts})
    Process.get(:stream_results) |> Map.fetch!(deployment.name)
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

  test "uses a fallback stream after a retryable primary failure" do
    body = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    Process.put(:stream_results, %{
      "deepseek-v4-flash" => {:error, %{type: :server_error, message: "down"}},
      "gpt-4o-mini" => {:ok, [:fallback_stream]}
    })

    assert {:ok, [:fallback_stream], deployment} =
             Fallback.stream("deepseek-v4-flash", body,
               key: "work-key",
               rid: "request-1",
               timeout: 4_000,
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert deployment.name == "gpt-4o-mini"
    assert_receive {:stream_call, "deepseek-v4-flash", ^body, primary_opts}
    assert primary_opts[:rid] == "request-1"
    assert primary_opts[:timeout] == 4_000
    assert_receive {:stream_call, "gpt-4o-mini", ^body, fallback_opts}
    assert fallback_opts[:rid] == "request-1"
    assert fallback_opts[:timeout] == 4_000
  end

  test "reports every cooling deployment in the fallback chain" do
    Cooldown.record_failure("openrouter", "deepseek-v4-flash")
    Cooldown.record_failure("openai-main", "gpt-4o-mini")

    assert {:error, %{type: :all_failed, errors: errors}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "work-key",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert errors == [
             {"deepseek-v4-flash", %{type: :cooling}},
             {"gpt-4o-mini", %{type: :cooling}}
           ]

    refute_received {:stream_call, _, _, _}
  end

  test "stops after a non-retryable provider failure" do
    Process.put(:stream_results, %{
      "deepseek-v4-flash" => {:error, %{type: :unknown_error, message: "bad request"}}
    })

    assert {:error, %{type: :unknown_error, message: "bad request"}} =
             Fallback.stream("deepseek-v4-flash", %{},
               key: "work-key",
               executor: Llmgateway.FallbackStreamTest.Executor
             )

    assert_receive {:stream_call, "deepseek-v4-flash", %{}, _}
    refute_received {:stream_call, "gpt-4o-mini", _, _}
  end

  test "does not retry duplicate names from nested fallback chains" do
    GenServer.stop(Router)

    config = %{
      "providers" => [
        %{name: "provider", api_key: nil, base_url: "https://example.test"}
      ],
      "models" => [
        model("primary"),
        model("secondary"),
        model("tertiary")
      ],
      "keys" => [],
      "fallbacks" => %{
        "primary" => ["secondary"],
        "secondary" => ["primary", "tertiary"]
      }
    }

    {:ok, _pid} = Router.start_link(config)

    Process.put(:stream_results, %{
      "primary" => {:error, %{type: :server_error}},
      "secondary" => {:error, %{type: :transport_error}},
      "tertiary" => {:ok, [:tertiary_stream]}
    })

    assert {:ok, [:tertiary_stream], %{name: "tertiary"}} =
             Fallback.stream("primary", %{}, executor: Llmgateway.FallbackStreamTest.Executor)

    assert_receive {:stream_call, "primary", %{}, _}
    assert_receive {:stream_call, "secondary", %{}, _}
    assert_receive {:stream_call, "tertiary", %{}, _}
    refute_received {:stream_call, _, _, _}
  end

  defp model(name) do
    %{
      name: name,
      provider_name: "provider",
      provider_type: :openai,
      upstream_model: name,
      context: 1,
      output_limit: 1,
      path: "/chat/completions",
      keys: nil
    }
  end
end
