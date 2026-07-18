defmodule Llmgateway.Config do
  @moduledoc """
  Parses the YAML config file, resolves `$VAR` env references,
  and enriches provider/model metadata from `llm_db`.
  """

  @doc """
  Load and parse a config YAML file.

  Returns `{:ok, parsed_config}` or `{:error, reason}`.
  """
  def load(path) do
    with {:ok, yaml} <- read_yaml(path),
         {:ok, resolved} <- resolve_env_vars(yaml),
         {:ok, validated} <- validate(resolved),
         {:ok, enriched} <- enrich_from_llm_db(validated) do
      {:ok, enriched}
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, content} when is_map(content) -> {:ok, content}
      {:ok, _} -> {:error, "config must be a top-level map"}
      {:error, %{message: msg}} -> {:error, "failed to parse YAML: #{msg}"}
      {:error, reason} -> {:error, "failed to parse YAML: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "failed to read YAML: #{Exception.message(e)}"}
  end

  defp resolve_env_vars(value) when is_binary(value) do
    if String.starts_with?(value, "$") do
      var_name = String.slice(value, 1..-1//1)

      case System.get_env(var_name) do
        nil -> {:error, "env var #{var_name} referenced but not set"}
        val -> {:ok, val}
      end
    else
      {:ok, value}
    end
  end

  defp resolve_env_vars(value) when is_map(value) do
    result =
      value
      |> Enum.map(fn {k, v} ->
        case resolve_env_vars(v) do
          {:ok, resolved} -> {:ok, {k, resolved}}
          {:error, _} = err -> err
        end
      end)
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {k, v}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, k, v)}}
        {:error, _} = err, _ -> {:halt, err}
      end)

    result
  end

  defp resolve_env_vars(value) when is_list(value) do
    result =
      value
      |> Enum.map(&resolve_env_vars/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, v}, {:ok, acc} -> {:cont, {:ok, acc ++ [v]}}
        {:error, _} = err, _ -> {:halt, err}
      end)

    result
  end

  defp resolve_env_vars(value), do: {:ok, value}

  defp validate(config) do
    errors = []

    errors =
      if is_map(config["providers"]) or is_list(config["providers"]) do
        errors
      else
        ["missing or invalid 'providers' section" | errors]
      end

    errors =
      if config["models"] do
        errors
      else
        ["missing 'models' section" | errors]
      end

    if errors == [] do
      {:ok, config}
    else
      {:error, Enum.join(errors, "; ")}
    end
  end

  defp enrich_from_llm_db(config) do
    providers = normalize_provider_list(config["providers"])
    models = normalize_model_list(config["models"])

    # Load llm_db (first query triggers lazy load)
    _ = LLMDB.model("openai:gpt-4o-mini")

    with {:ok, enriched_providers} <- enrich_providers(providers),
         {:ok, enriched_models} <- enrich_models(models, enriched_providers) do
      config =
        config
        |> Map.put("providers", enriched_providers)
        |> Map.put("models", enriched_models)
        |> Map.put("keys", normalize_key_list(config["keys"]))
        |> Map.put("fallbacks", config["fallbacks"] || [])

      {:ok, config}
    end
  end

  defp normalize_provider_list(list) when is_list(list), do: list
  defp normalize_provider_list(nil), do: []

  defp normalize_model_list(list) when is_list(list), do: list
  defp normalize_model_list(nil), do: []

  defp normalize_key_list(list) when is_list(list), do: list
  defp normalize_key_list(nil), do: []

  defp enrich_providers(providers) do
    result =
      providers
      |> Enum.map(fn p ->
        type = String.to_existing_atom(p["type"])

        case LLMDB.provider(type) do
          {:ok, provider_meta} ->
            {:ok,
             %{
               name: p["name"],
               type: type,
               api_key: p["api_key"],
               runtime: provider_meta.runtime,
               base_url: (provider_meta.runtime && provider_meta.runtime.base_url) ||
                           provider_meta.base_url
             }}

          :error ->
            {:error, "unknown provider type '#{p["type"]}' for provider '#{p["name"]}'"}
        end
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, p}, {:ok, acc} -> {:cont, {:ok, acc ++ [p]}}
        {:error, _} = err, _ -> {:halt, err}
      end)

    result
  end

  defp enrich_models(models, providers) do
    provider_map = Map.new(providers, &{&1.name, &1})

    result =
      models
      |> Enum.map(fn m ->
        provider = provider_map[m["provider"]]

        if is_nil(provider) do
          {:error, "model '#{m["name"]}' references unknown provider '#{m["provider"]}'"}
        else
          model_id = m["model"]
          upstream_model = resolve_upstream_model(provider.type, model_id)

          {context, output_limit} =
            case LLMDB.model({provider.type, upstream_model}) do
              {:ok, md} ->
                {md.limits.context, md.limits.output}

              _ ->
                {nil, nil}
            end

          {:ok,
           %{
             name: m["name"],
             provider_name: provider.name,
             provider_type: provider.type,
             upstream_model: upstream_model,
             keys: m["keys"],
             context: context,
             output_limit: output_limit
           }}
        end
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, m}, {:ok, acc} -> {:cont, {:ok, acc ++ [m]}}
        {:error, _} = err, _ -> {:halt, err}
      end)

    result
  end

  # Handle provider-prefixed model ids like "deepseek/deepseek-v4-flash"
  # by stripping the prefix since we already have the provider context.
  defp resolve_upstream_model(_provider_type, model_id) do
    case String.split(model_id, "/", parts: 2) do
      [_, rest] -> rest
      _ -> model_id
    end
  end
end