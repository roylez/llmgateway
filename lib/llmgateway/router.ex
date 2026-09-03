defmodule Llmgateway.Router do
  require Logger

  @moduledoc """
  GenServer that holds the routing state and delegates all routing logic to
  the pure `Llmgateway.Router.Core` functions.

  ## Multi-deployment models

  The same model name can have multiple deployments with different providers
  and key restrictions. Resolution returns every accessible deployment by
  descending group priority. Equal priorities retain YAML order. The default
  resolver returns the first deployment from this ordered set.

  ## Live Copilot limits

  `Llmgateway.Auth.GitHubDevice` publishes its model-limits snapshot via
  `cast_live_limits/2`; the Router merges it into its state. Requests never
  block on the auth server: while the snapshot is absent (server not started,
  or limits not fetched yet), Copilot models resolve with their configured
  limits.
  """

  use GenServer

  alias Llmgateway.{Auth.GitHubDevice, Deployment, Router.Core}

  @doc "Build discovery metadata for a resolved deployment."
  def discovery_metadata(%Deployment{} = deployment) do
    Core.discovery_metadata(deployment)
  end

  # ── Client API ────────────────────────────────────────────

  @doc "Start the router with a parsed config map."
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Resolve a model name to its highest-priority accessible deployment.

  Returns `{:ok, %Deployment{}, fallbacks}` or `{:error, reason}`.
  """
  def resolve_model(name, opts \\ []) do
    GenServer.call(__MODULE__, {:resolve_model, name, opts}, 5_000)
  end

  @doc """
  Resolve a model name to every accessible deployment in priority order.

  Returns `{:ok, [%Deployment{}], fallbacks}` or `{:error, reason}`.
  """
  def resolve_deployments(name, opts \\ []) do
    GenServer.call(__MODULE__, {:resolve_deployments, name, opts}, 5_000)
  end

  @doc "Resolve an API key token to a key name."
  def resolve_key(token) do
    GenServer.call(__MODULE__, {:resolve_key, token})
  end

  @doc "List all models accessible by the given key name."
  def list_models(opts \\ []) do
    GenServer.call(__MODULE__, {:list_models, opts})
  end

  @doc "Reload config from a file path."
  def reload(config_path) do
    case Llmgateway.Config.load(config_path) do
      {:ok, config} ->
        GenServer.call(__MODULE__, {:reload, config})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merge a live-limits snapshot from a Copilot auth server into Router state.

  Called by `Llmgateway.Auth.GitHubDevice` whenever its model cache changes.
  Safe to call when the Router is not running (e.g. tests that start no
  router).
  """
  def cast_live_limits(provider_name, models) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, {:live_limits, provider_name, models})
        :ok
    end
  end

  # ── Server callbacks ──────────────────────────────────────

  @impl true
  def init(config) do
    state = Core.build_state(config)
    request_live_limits(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:resolve_model, name, opts}, _from, state) do
    result = Core.resolve_deployments(name, opts[:key], state)

    reply =
      case result do
        {:ok, [deployment | _], fallbacks} -> {:ok, deployment, fallbacks}
        {:error, :not_found} -> {:error, :not_found}
        {:error, :forbidden, fallbacks} -> {:error, :forbidden, fallbacks}
        {:error, :forbidden} -> {:error, :forbidden}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:resolve_deployments, name, opts}, _from, state) do
    {:reply, Core.resolve_deployments(name, opts[:key], state), state}
  end

  @impl true
  def handle_call({:resolve_key, token}, _from, state) do
    {:reply, Core.resolve_key(token, state), state}
  end

  @impl true
  def handle_call({:list_models, opts}, _from, state) do
    {:reply, Core.list_models(opts[:key], state), state}
  end

  @impl true
  def handle_call({:reload, config}, _from, _state) do
    state = Core.build_state(config)
    request_live_limits(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:live_limits, provider_name, models}, state) do
    {:noreply, Core.put_live_limits(state, provider_name, models)}
  end

  # ── Helpers ───────────────────────────────────────────────

  defp request_live_limits(state) do
    for {provider_name, provider} <- state.providers,
        provider[:type] == :github_copilot,
        server = Llmgateway.ProviderRegistry.github_device(provider_name),
        server != nil do
      GitHubDevice.request_live_limits(server)
    end
  end

end
