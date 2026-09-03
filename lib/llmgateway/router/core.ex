defmodule Llmgateway.Router.Core do
  @moduledoc """
  Pure routing logic over an explicit state snapshot.

  No process lookups, no GenServer calls: every function takes the state
  (or a deployment) and returns data. `Llmgateway.Router` owns this state
  in a GenServer and delegates here.
  """

  require Logger

  alias Llmgateway.Deployment

  @enforce_keys [:providers, :models, :keys, :aliases, :invalid_aliases, :fallbacks, :live_limits]
  defstruct [:providers, :models, :keys, :aliases, :invalid_aliases, :fallbacks, :live_limits]

  @type t :: %__MODULE__{
          providers: %{optional(String.t()) => map()},
          models: %{optional(String.t()) => [map()]},
          keys: %{optional(String.t()) => String.t()},
          aliases: %{optional(String.t()) => %{optional(String.t()) => String.t()}},
          invalid_aliases: %{optional(String.t()) => MapSet.t(String.t())},
          fallbacks: map(),
          live_limits: %{optional({String.t(), String.t()}) => map()}
        }

  @doc "Build a state snapshot from a parsed config map."
  def build_state(config) do
    providers = Map.new(config["providers"], &{&1.name, &1})
    models = config["models"] |> Enum.group_by(& &1.name)
    keys = build_key_map(config["keys"])
    {aliases, invalid_aliases} = build_alias_state(config["keys"], models)

    %__MODULE__{
      providers: providers,
      models: models,
      keys: keys,
      aliases: aliases,
      invalid_aliases: invalid_aliases,
      fallbacks: config["fallbacks"] || [],
      live_limits: %{}
    }
  end

  @doc """
  Merge a live-limits snapshot from one Copilot auth server into the state.

  `models` maps upstream model ID to `%{context: _, output: _}` (entries may
  omit either key). Copilot deployments then resolve and list with these
  limits instead of their configured values.
  """
  def put_live_limits(%__MODULE__{} = state, provider_name, models) when is_map(models) do
    limits = Map.new(models, fn {model, meta} -> {{provider_name, model}, meta} end)
    %{state | live_limits: Map.merge(state.live_limits, limits)}
  end

  def put_live_limits(%__MODULE__{} = state, _provider_name, _models), do: state

  @doc """
  Resolve a model name to every accessible deployment in priority order.

  Returns `{:ok, [%Deployment{}], fallbacks}`, `{:error, :not_found}`, or
  `{:error, :forbidden}` (with fallbacks when a chain exists).
  """
  def resolve_deployments(name, key_name, %__MODULE__{} = state) do
    case alias_target(name, key_name, state) do
      {:ok, backing_name} ->
        resolve_deployments_for(name, backing_name, key_name, state)

      :invalid ->
        {:error, :not_found}

      :ordinary ->
        if is_map_key(state.models, name) do
          resolve_deployments_for(name, name, key_name, state)
        else
          {:error, :not_found}
        end
    end
  end

  @doc "Resolve an API key token to a key name."
  def resolve_key(token, %__MODULE__{keys: keys}) do
    Enum.find_value(keys, {:error, :invalid_key}, fn {name, value} ->
      if Plug.Crypto.secure_compare(value, token), do: {:ok, name}
    end)
  end

  @doc "List all models accessible by the given key name."
  def list_models(key_name, %__MODULE__{} = state) do
    aliases = Map.get(state.aliases, key_name, %{})

    models =
      state.models
      |> Enum.reject(fn {name, _configs} -> Map.has_key?(aliases, name) end)
      |> Enum.flat_map(fn {name, configs} ->
        case configs |> find_accessible(key_name) |> order_by_priority() do
          [] -> []
          [m | _] -> [model_metadata(name, apply_live_limits(m, state))]
        end
      end)

    aliases =
      Enum.flat_map(aliases, fn {alias_name, backing_name} ->
        case state.models
             |> Map.fetch!(backing_name)
             |> find_accessible(key_name)
             |> order_by_priority() do
          [model | _] -> [model_metadata(alias_name, apply_live_limits(model, state))]
          [] -> []
        end
      end)

    models ++ aliases
  end

  @doc "Build discovery metadata for a resolved deployment."
  def discovery_metadata(%Deployment{} = deployment) do
    model_metadata(deployment.name, deployment)
  end

  defp model_metadata(name, model) do
    metadata = model.metadata || %{}

    limits =
      Map.merge(metadata[:limits] || %{}, %{context: model.context, output: model.output_limit})

    %{
      id: name,
      owned_by: Atom.to_string(model.provider_type),
      limits: limits,
      capabilities: metadata[:capabilities],
      modalities: metadata[:modalities],
      execution: metadata[:execution],
      extra: metadata[:extra]
    }
  end

  # ── State construction ────────────────────────────────────

  defp build_key_map(keys) when is_list(keys) do
    Map.new(keys, &{&1["name"], &1["value"]})
  end

  defp build_key_map(nil), do: %{}

  defp build_alias_state(keys, models) when is_list(keys) do
    Enum.reduce(keys, {%{}, %{}}, fn key, {valid, invalid} ->
      key_name = key["name"]
      aliases = Map.get(key, "aliases", %{})

      Enum.reduce(aliases, {valid, invalid}, fn {alias_name, backing_name}, {valid, invalid} ->
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
          {Map.update(
             valid,
             key_name,
             %{alias_name => backing_name},
             &Map.put(&1, alias_name, backing_name)
           ), invalid}
        end
      end)
    end)
  end

  defp build_alias_state(_, _), do: {%{}, %{}}

  # ── Model resolution ──────────────────────────────────────

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

  # ── Live Copilot limits ───────────────────────────────────

  # Overrides config limits when the auth server has published a snapshot;
  # absent snapshot (no auth server, no fetch yet) keeps config values.
  defp apply_live_limits(
         %{provider_type: :github_copilot, provider_name: provider_name, upstream_model: model} =
           config,
         state
       ) do
    case Map.fetch(state.live_limits, {provider_name, model}) do
      {:ok, %{context: context, output: output}} ->
        %{
          config
          | context: context || config.context,
            output_limit: output || config.output_limit
        }

      _ ->
        config
    end
  end

  defp apply_live_limits(config, _state), do: config

  # ── Deployment building ───────────────────────────────────

  defp build_deployment(model_config, state, public_name) do
    model_config = apply_live_limits(model_config, state)
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
        metadata: Map.get(model_config, :metadata),
        path: model_config.path
      }

      {:ok, deployment}
    end
  end

  # ── Fallback resolution ──────────────────────────────────

  defp find_fallbacks(model_name, state) do
    Map.get(state.fallbacks, model_name) || Map.get(state.fallbacks, "*") || []
  end
end
