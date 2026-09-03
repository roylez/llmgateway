defmodule Llmgateway.Runtime do
  @moduledoc """
  Supervised runtime/config manager.

  Owns the validated config snapshot loaded at boot and reports gateway
  readiness for the `/ready` endpoint. The gateway fails boot loudly when
  the config is missing or invalid, so a running instance always holds a
  valid snapshot; readiness additionally requires the required children
  (the router) to be alive.

  `/health` (liveness) does not consult this module — it reports 200
  whenever the HTTP server is up.
  """

  use GenServer

  alias Llmgateway.Router

  # ── Client API ────────────────────────────────────────────

  @doc "Start the runtime manager with the validated config snapshot."
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  True when a valid runtime snapshot is loaded and the required children
  are alive. Returns false when the manager itself is not running.
  """
  def ready? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> GenServer.call(__MODULE__, :ready?)
    end
  end

  @doc "The current config snapshot. Raises when the manager is not running."
  def config do
    GenServer.call(__MODULE__, :config)
  end

  # ── Server callbacks ─────────────────────────────────────

  @impl true
  def init(config) do
    {:ok, %{config: config}}
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call(:ready?, _from, state) do
    {:reply, snapshot_valid?(state.config) and router_alive?(), state}
  end

  defp snapshot_valid?(config) when is_map(config), do: true
  defp snapshot_valid?(_), do: false

  defp router_alive?, do: Process.whereis(Router) != nil
end
