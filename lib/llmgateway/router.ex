defmodule Llmgateway.Router do
  @moduledoc """
  GenServer that resolves model names to deployments, validates key access,
  and provides fallback chains.

  ## State

    - `:providers` — map of provider_name → enriched provider config
    - `:models` — map of model_name → enriched model config
    - `:keys` — map of key_name → api_key value
    - `:fallbacks` — list of %{primary: model_name, fallbacks: [model_name, ...]}
    - `:model_key_map` — map of key_name → MapSet of accessible model names.
           The special key `:_any` holds models accessible by all keys.
  """

  use GenServer

  alias Llmgateway.Deployment

  # ── Client API ────────────────────────────────────────────

  @doc "Start the router with a parsed config map."
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Resolve a model name to a deployment.

  Returns `{:ok, %Deployment{}, fallbacks}` or `{:error, reason}`.
  When a key is provided, checks key access first — if the primary model is
  inaccessible but fallbacks exist, the primary is skipped and fallbacks returned.
  """
  def resolve_model(name, opts \\ []) do
    GenServer.call(__MODULE__, {:resolve_model, name, opts}, :infinity)
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
    key_name = opts[:key]

    case state.models[name] do
      nil ->
        {:reply, {:error, :not_found}, state}

      model_config ->
        case check_key_access(model_config, key_name, state) do
          :ok ->
            case build_deployment(model_config, state) do
              {:ok, deployment} ->
                fallbacks = find_fallbacks(name, state)
                {:reply, {:ok, deployment, fallbacks}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, :forbidden} ->
            if has_fallback?(name, state) do
              fallbacks = find_fallbacks(name, state)
              {:reply, {:error, :forbidden, fallbacks}, state}
            else
              {:reply, {:error, :forbidden}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:resolve_key, token}, _from, state) do
    result =
      Enum.find_value(state.keys, {:error, :invalid_key}, fn {name, value} ->
        if secure_compare(value, token), do: {:ok, name}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_models, opts}, _from, state) do
    key_name = opts[:key]
    allowed = if key_name, do: accessible_models(key_name, state), else: MapSet.new(Map.keys(state.models))

    models =
      state.models
      |> Enum.filter(fn {name, _} -> name in allowed end)
      |> Enum.map(fn {name, m} ->
        %{
          id: name,
          object: "model",
          owned_by: Atom.to_string(m.provider_type),
          limits: %{
            context: m.context,
            output: m.output_limit
          }
        }
      end)

    {:reply, models, state}
  end

  @impl true
  def handle_call({:reload, config}, _from, _state) do
    new_state = build_state(config)
    {:reply, :ok, new_state}
  end

  # ── State construction ────────────────────────────────────

  defp build_state(config) do
    providers = Map.new(config["providers"], &{&1.name, &1})
    models = Map.new(config["models"], &{&1.name, &1})
    keys = build_key_map(config["keys"])
    model_key_map = build_model_key_map(config["models"], keys)
    fallbacks = config["fallbacks"] || []

    %{
      providers: providers,
      models: models,
      keys: keys,
      fallbacks: fallbacks,
      model_key_map: model_key_map
    }
  end

  defp build_key_map(keys) when is_list(keys) do
    Map.new(keys, &{&1["name"], &1["value"]})
  end

  defp build_key_map(nil), do: %{}

  defp build_model_key_map(models, _keys) do
    Enum.reduce(models, %{_any: MapSet.new()}, fn m, acc ->
      if m.keys do
        Enum.reduce(m.keys, acc, fn key_name, inner_acc ->
          Map.update(inner_acc, key_name, MapSet.new([m.name]), &MapSet.put(&1, m.name))
        end)
      else
        Map.update(acc, :_any, MapSet.new([m.name]), &MapSet.put(&1, m.name))
      end
    end)
  end

  # ── Access control ────────────────────────────────────────

  defp check_key_access(_model_config, nil, _state), do: :ok

  defp check_key_access(model_config, key_name, state) do
    if model_config.keys do
      key_models = accessible_models(key_name, state)

      if model_config.name in key_models, do: :ok, else: {:error, :forbidden}
    else
      :ok
    end
  end

  defp accessible_models(key_name, state) do
    key_specific = Map.get(state.model_key_map, key_name, MapSet.new())
    any_model = Map.get(state.model_key_map, :_any, MapSet.new())
    MapSet.union(key_specific, any_model)
  end

  # ── Deployment building ───────────────────────────────────

  defp build_deployment(model_config, state) do
    provider = state.providers[model_config.provider_name]

    if is_nil(provider) do
      {:error, "provider '#{model_config.provider_name}' not found"}
    else
      deployment = %Deployment{
        name: model_config.name,
        provider_name: model_config.provider_name,
        provider_type: model_config.provider_type,
        upstream_model: model_config.upstream_model,
        api_key: provider.api_key,
        base_url: provider.base_url,
        context: model_config.context,
        output_limit: model_config.output_limit
      }

      {:ok, deployment}
    end
  end

  # ── Fallback resolution ──────────────────────────────────

  defp find_fallbacks(model_name, state) do
    state.fallbacks
    |> Enum.find_value([], fn
      %{primary: ^model_name, fallbacks: fbs} -> fbs
      %{^model_name => fbs} -> fbs  # literal map format
      [%{^model_name => fbs}] -> fbs
      _ -> nil
    end)
    |> case do
      fbs when is_list(fbs) -> fbs
      nil ->
        # Check for generic fallback
        state.fallbacks
        |> Enum.find_value([], fn
          %{primary: "*", fallbacks: fbs} -> fbs
          %{"*" => fbs} -> fbs
          [%{"*" => fbs}] -> fbs
          _ -> nil
        end)
        |> case do
          nil -> []
          fbs -> fbs
        end
    end
  end

  defp has_fallback?(model_name, state) do
    find_fallbacks(model_name, state) != []
  end

  # ── Helpers ──────────────────────────────────────────────

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    # Constant-time comparison to prevent timing attacks
    a_bytes = :erlang.binary_to_list(a)
    b_bytes = :erlang.binary_to_list(b)

    if length(a_bytes) == length(b_bytes) do
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end) == 0
    else
      false
    end
  end

  defp secure_compare(_, _), do: false
end