defmodule Llmgateway.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Llmgateway.Telemetry

  test "logs the LiteLLM agent identifier as the app" do
    output =
      capture_log(fn ->
        Telemetry.handle_event(
          [:llmgateway, :request, :stop],
          %{duration: System.convert_time_unit(220, :millisecond, :native)},
          %{
            app: "OMP",
            model: "fast",
            provider: :github_copilot,
            upstream_model: "gpt-5.6-luna",
            usage: %{
              "prompt_tokens" => 180,
              "completion_tokens" => 13,
              "total_tokens" => 193
            }
          },
          nil
        )
      end)

    assert output =~ "app=OMP model=fast upstream=github_copilot:gpt-5.6-luna"
    assert output =~ "input=180 output=13 total=193 time=220ms"
  end
end
