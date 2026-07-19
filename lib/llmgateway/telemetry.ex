defmodule Llmgateway.Telemetry do
  @moduledoc """
  Telemetry events emitted by the proxy.

  ## Events

  - `[:llmgateway, :request, :start]` — fired before calling a provider
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{model: string, deployment: string, provider: atom}`

  - `[:llmgateway, :request, :stop]` — fired after a successful response
    - Measurements: `%{duration: integer}` (native time units)
    - Metadata: `%{model: string, deployment: string, provider: atom, status: integer}`

  - `[:llmgateway, :request, :exception]` — fired on error
    - Measurements: `%{duration: integer}`
    - Metadata: `%{model: string, deployment: string, provider: atom, kind: atom, reason: term}`

  - `[:llmgateway, :fallback, :triggered]` — fired when a fallback is attempted
    - Measurements: `%{}`
    - Metadata: `%{from: string, to: string, reason: term}`

  ## Attaching a handler

      :telemetry.attach_many(
        "llmgateway-logger",
        [
          [:llmgateway, :request, :start],
          [:llmgateway, :request, :stop],
          [:llmgateway, :request, :exception],
          [:llmgateway, :fallback, :triggered]
        ],
        &Llmgateway.Telemetry.handle_event/4,
        nil
      )
  """

  require Logger

  @doc false
  def request_start(deployment) do
    meta = %{
      model: deployment.name,
      upstream_model: deployment.upstream_model,
      deployment: deployment.name,
      provider: deployment.provider_type
    }

    :telemetry.execute(
      [:llmgateway, :request, :start],
      %{system_time: System.system_time()},
      meta
    )

    {System.monotonic_time(), meta}
  end

  def request_stop({start_time, meta}, status, usage \\ nil) do
    duration = System.monotonic_time() - start_time
    meta = if usage, do: Map.put(meta, :usage, usage), else: meta

    :telemetry.execute(
      [:llmgateway, :request, :stop],
      %{duration: duration},
      Map.put(meta, :status, status)
    )
  end

  @doc false
  def request_exception({start_time, meta}, kind, reason) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:llmgateway, :request, :exception],
      %{duration: duration},
      Map.merge(meta, %{kind: kind, reason: reason})
    )
  end

  @doc false
  def fallback_triggered(from, to, reason) do
    :telemetry.execute(
      [:llmgateway, :fallback, :triggered],
      %{},
      %{from: from, to: to, reason: reason}
    )
  end

  @doc """
  Default telemetry handler that logs events to stdout.

  Attach with `Llmgateway.Telemetry.attach_default_logger/0`.
  """
  def attach_default_logger do
    :telemetry.attach_many(
      "llmgateway-default-logger",
      [
        [:llmgateway, :request, :start],
        [:llmgateway, :request, :stop],
        [:llmgateway, :request, :exception],
        [:llmgateway, :fallback, :triggered]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:llmgateway, :request, :start], _measurements, _meta, _config) do
    # Suppressed — merged into stop event
    :ok
  end

  def handle_event([:llmgateway, :request, :stop], measurements, meta, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    upstream = Map.get(meta, :upstream_model, meta.model)

    usage_str =
      case Map.get(meta, :usage) do
        nil ->
          ""

        u ->
          " input=#{u["prompt_tokens"] || "?"} output=#{u["completion_tokens"] || "?"} total=#{u["total_tokens"] || "?"}"
      end

    Logger.info(
      "[llmgateway] model=#{meta.model} upstream=#{upstream} provider=#{meta.provider}#{usage_str} time=#{ms}ms"
    )
  end

  def handle_event([:llmgateway, :request, :exception], measurements, meta, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.warning("[llmgateway] ✗ #{meta.model} #{meta.kind}: #{inspect(meta.reason)} (#{ms}ms)")
  end

  def handle_event([:llmgateway, :fallback, :triggered], _measurements, meta, _config) do
    Logger.info("[llmgateway] ↪ fallback #{meta.from} → #{meta.to}")
  end
end
