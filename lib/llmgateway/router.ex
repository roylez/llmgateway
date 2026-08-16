defmodule Llmgateway.Router do
  require Logger

  @moduledoc """
  GenServer that resolves model names to deployments, validates key access,
  and provides fallback chains.

  ## Multi-deployment models

  The same model name can have multiple deployments with different providers
  and key restrictions. Resolution returns every accessible deployment by
  descending group priority. Equal priorities retain YAML order. The default
  resolver returns the first deployment from this ordered set.
  """

  use GenServer

  alias Llmgateway.Deployment

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

  # ── Server callbacks ──────────────────────────────────────

  @impl true
  def init(config) do
    state = build_state(config)
    {:ok, state}
  end

  @impl true
  def handle_call({:resolve_model, name, opts}, _from, state) do
    result = resolve_deployments(name, opts[:key], state)

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
    {:reply, resolve_deployments(name, opts[:key], state), state}
  end

  @impl true
  def handle_call({:resolve_key, token}, _from, state) do
    result =
      Enum.find_value(state.keys, {:error, :invalid_key}, fn {name, value} ->
        if Plug.Crypto.secure_compare(value, token), do: {:ok, name}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_models, opts}, _from, state) do
    key_name = opts[:key]
    aliases = Map.get(state.aliases, key_name, %{})

    models =
      state.models
      |> Enum.reject(fn {name, _configs} -> Map.has_key?(aliases, name) end)
      |> Enum.flat_map(fn {name, configs} ->
        case configs |> find_accessible(key_name) |> order_by_priority() do
          [] ->
            []

          [m | _] ->
            [model_metadata(name, m)]
        end
      end)

    aliases =
      Enum.flat_map(aliases, fn {alias_name, backing_name} ->
        case state.models
             |> Map.fetch!(backing_name)
             |> find_accessible(key_name)
             |> order_by_priority() do
          [model | _] -> [model_metadata(alias_name, model)]
          [] -> []
        end
      end)

    {:reply, models ++ aliases, state}
  end

  defp model_metadata(name, model) do
    %{
      id: name,
      object: "model",
      owned_by: Atom.to_string(model.provider_type),
      limits: %{context: model.context, output: model.output_limit}
    }
  end

  # ── State construction ────────────────────────────────────

  defp build_state(config) do
    providers = Map.new(config["providers"], &{&1.name, &1})

    models =
      config["models"]
      |> Enum.group_by(& &1.name)

    keys = build_key_map(config["keys"])
    {aliases, invalid_aliases} = build_alias_state(config["keys"], models)
    fallbacks = config["fallbacks"] || []

    %{
      providers: providers,
      models: models,
      keys: keys,
      aliases: aliases,
      invalid_aliases: invalid_aliases,
      fallbacks: fallbacks
    }
  end

  defp build_key_map(keys) when is_list(keys) do
    Map.new(keys, &{&1["name"], &1["value"]})
  end

  defp build_key_map(nil), do: %{}

  defp build_alias_state(keys, models) when is_list(keys) do
    Enum.reduce(keys, {%{}, %{}}, fn key, {valid, invalid} ->
      key_name = key["name"]
      aliases = Map.get(key, "aliases", %{})

      Enum.reduce(aliases, {valid, invalid}, fn {alias_name, backing_name},
                                                {valid, invalid} ->
        accessible =
          case Map.get(models, backing_name) do
            nil -> false
            configs -> find_accessible(configs, key_name) != []
          end

        if Map.has_key?(aliases, backing_name) or not accessible do
          Logger.warning(
            "[config] Alias '#{alias_name}' for key '#{key_name}' targets unavailable model '#{backing_name}'; alias ignored"
          )

          {valid,
           Map.update(invalid, key_name, MapSet.new([alias_name]), &MapSet.put(&1, alias_name))}
        else
          {Map.update(valid, key_name, %{alias_name => backing_name},
             &Map.put(&1, alias_name, backing_name)), invalid}
        end
      end)
    end)
  end

  defp build_alias_state(_, _), do: {%{}, %{}}

  # ── Model resolution (pattern matching on key access) ────

  defp resolve_deployments(name, key_name, state) do
    case alias_target(name, key_name, state) do
      {:ok, backing_name} -> resolve_deployments_for(name, backing_name, key_name, state)
      :invalid -> {:error, :not_found}
      :ordinary ->
        if is_map_key(state.models, name) do
          resolve_deployments_for(name, name, key_name, state)
        else
          {:error, :not_found}
        end
    end
  end

  defp alias_target(name, key_name, state) do
    aliases = Map.get(state.aliases, key_name, %{})

    cond do
      Map.has_key?(aliases, name) ->
        {:ok, aliases[name]}

      MapSet.member?(Map.get(state.invalid_aliases, key_name, MapSet.new()), name) ->
        :invalid

      true ->
        :ordinary
    end
  end

  defp resolve_deployments_for(public_name, backing_name, key_name, state) do
    fallbacks = find_fallbacks(backing_name, state)

    deployments =
      state.models
      |> Map.fetch!(backing_name)
      |> find_accessible(key_name)
      |> order_by_priority()
      |> Enum.reduce_while({:ok, []}, fn config, {:ok, acc} ->
        case build_deployment(config, state, public_name) do
          {:ok, deployment} -> {:cont, {:ok, [deployment | acc]}}
          {:error, _} -> {:halt, :forbidden}
        end
      end)

    case deployments do
      {:ok, []} when fallbacks != [] -> {:error, :forbidden, fallbacks}
      {:ok, []} -> {:error, :forbidden}
      {:ok, deployments} -> {:ok, Enum.reverse(deployments), fallbacks}
      :forbidden when fallbacks != [] -> {:error, :forbidden, fallbacks}
      :forbidden -> {:error, :forbidden}
    end
  end

  defp find_accessible(configs, key_name) do
    Enum.filter(configs, fn
      %{keys: nil} -> true
      %{keys: keys} when is_list(keys) -> key_name != nil and key_name in keys
      _ -> true
    end)
  end

  defp order_by_priority(configs) do
    Enum.sort_by(configs, & &1.priority, :desc)
  end

  # ── Deployment building ───────────────────────────────────

  defp build_deployment(model_config, state, public_name) do
    provider = state.providers[model_config.provider_name]

    if is_nil(provider) do
      {:error, "provider '#{model_config.provider_name}' not found"}
    else
      deployment = %Deployment{
        name: public_name,
        provider_name: model_config.provider_name,
        provider_type: model_config.provider_type,
        upstream_model: model_config.upstream_model,
        api_key: provider.api_key,
        base_url: provider.base_url,
        context: model_config.context,
        output_limit: model_config.output_limit,
        path: model_config.path
      }

      {:ok, deployment}
    end
  end

  # ── Fallback resolution ──────────────────────────────────

  defp find_fallbacks(model_name, %{fallbacks: fallbacks}) do
    Map.get(fallbacks, model_name) || Map.get(fallbacks, "*") || []
  end

end
