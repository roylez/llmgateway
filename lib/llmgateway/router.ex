defmodule Llmgateway.Router do
  @moduledoc """
  GenServer that resolves model names to deployments, validates key access,
  and provides fallback chains.

  ## Multi-deployment models

  The same model name can appear multiple times with different providers
  and key restrictions. Resolution picks the first deployment accessible
  by the current key:

      models:
        - name: deepseek-v4-flash
          provider: openrouter-work
          keys: [work]
        - name: deepseek-v4-flash
          provider: openrouter
          keys: [personal]

  A request with `work` key gets the first entry; `personal` gets the second.
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

  When multiple deployments share a name, returns the first one accessible
  by the given key. Returns `{:ok, %Deployment{}, fallbacks}` or `{:error, reason}`.
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
    fallbacks = find_fallbacks(name, state)

    case resolve(name, key_name, state) do
      {:ok, deployment} ->
        {:reply, {:ok, deployment, fallbacks}, state}

      :not_found ->
        {:reply, {:error, :not_found}, state}

      :forbidden when fallbacks != [] ->
        {:reply, {:error, :forbidden, fallbacks}, state}

      :forbidden ->
        {:reply, {:error, :forbidden}, state}
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

    models =
      state.models
      |> Enum.flat_map(fn {name, configs} ->
        case find_accessible(configs, key_name) do
          nil -> []
          m ->
            [%{
              id: name,
              object: "model",
              owned_by: Atom.to_string(m.provider_type),
              limits: %{context: m.context, output: m.output_limit}
            }]
        end
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

    # Group models by name — same name can have multiple deployments
    models =
      config["models"]
      |> Enum.group_by(& &1.name)

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

  # ── Model resolution (pattern matching on key access) ────

  # No model entries for this name
  defp resolve(name, _key_name, %{models: models}) when not is_map_key(models, name), do: :not_found

  # No key provided — take the first deployment
  defp resolve(name, nil, state) do
    state.models[name]
    |> List.first()
    |> build_deployment(state)
  end

  # Key provided — find first deployment accessible by this key
  defp resolve(name, key_name, state) do
    state.models[name]
    |> Enum.find_value(:forbidden, fn
      %{keys: nil} = config -> build_deployment(config, state)
      %{keys: keys} = config when is_list(keys) ->
        if key_name in keys, do: build_deployment(config, state), else: nil
      config -> build_deployment(config, state)
    end)
  end

  defp find_accessible(configs, nil), do: List.first(configs)

  defp find_accessible(configs, key_name) do
    Enum.find(configs, fn
      %{keys: nil} -> true
      %{keys: keys} when is_list(keys) -> key_name in keys
      _ -> true
    end)
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
      %{^model_name => fbs} -> fbs
      [%{^model_name => fbs}] -> fbs
      _ -> nil
    end)
    |> case do
      fbs when is_list(fbs) -> fbs
      nil ->
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
