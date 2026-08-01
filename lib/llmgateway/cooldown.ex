defmodule Llmgateway.Cooldown do
  @moduledoc "Cooldown tracking. One Agent; state keyed by {provider_name, model_name}."
  use Agent

  def start_link(opts) do
    window_ms = Keyword.get(opts, :window_ms, 0)
    Agent.start_link(fn -> %{window_ms: window_ms, cooling: %{}} end, name: __MODULE__)
  end

  # Mark {provider_name, model_name} cooling until now + window.
  # No-op when the Agent is absent (feature off) or window_ms == 0.
  def record_failure(provider_name, model_name) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, fn
          %{window_ms: w, cooling: cooling} when w > 0 ->
            now = System.monotonic_time(:millisecond)
            %{window_ms: w, cooling: Map.put(cooling, {provider_name, model_name}, now + w)}

          state ->
            state
        end)

        :ok
    end
  end

  def active?(provider_name, model_name) do
    case Process.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        now = System.monotonic_time(:millisecond)

        Agent.get(pid, fn %{cooling: cooling} ->
          case Map.fetch(cooling, {provider_name, model_name}) do
            {:ok, expiry} -> now < expiry
            :error -> false
          end
        end)
    end
  end
end
