defmodule Llmgateway.CooldownTest do
  use ExUnit.Case
  alias Llmgateway.{Config, Cooldown, Router}
  @fixtures_path "test/fixtures"

  setup do
    start_supervised!({Cooldown, window_ms: 60_000})
    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    {:ok, _} = Router.start_link(config)
    :ok
  end

  test "unit: start inactive, become cooling after record_failure, per {provider, model}" do
    assert Cooldown.active?("openrouter", "deepseek-v4-flash") == false
    Cooldown.record_failure("openrouter", "deepseek-v4-flash")
    assert Cooldown.active?("openrouter", "deepseek-v4-flash") == true
    # same model name, different provider, stays inactive
    assert Cooldown.active?("openai-main", "deepseek-v4-flash") == false
  end

  test "skips cooling-down deployments without calling a provider" do
    # primary deepseek-v4-flash (openrouter) + fallback gpt-4o-mini (openai-main)
    Cooldown.record_failure("openrouter", "deepseek-v4-flash")
    Cooldown.record_failure("openai-main", "gpt-4o-mini")

    assert {:error, %{type: :all_failed, errors: errors}} =
             Llmgateway.generate_text("deepseek-v4-flash",
               %{"messages" => [%{"role" => "user", "content" => "hi"}]},
               key: "work-key"
             )

    assert Enum.all?(errors, fn {_name, reason} -> reason.type == :cooling end)
  end
end
