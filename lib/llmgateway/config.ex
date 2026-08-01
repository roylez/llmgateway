defmodule Llmgateway.Config do
  @moduledoc """
  Parses the YAML config file, resolves `$VAR` env references,
  and enriches provider/model metadata from `llm_db`.
  """

  # After a retryable failure, skip the {provider, model} pair for this many seconds.
  # Reasonable default (60s); explicit 0 disables.
  @default_cooldown_seconds 60

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
    value
    |> Enum.map(&resolve_env_vars/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, v}, {:ok, acc} -> {:cont, {:ok, [v | acc]}}
      {:error, _} = err, _ -> {:halt, err}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
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
      case validate_models(config["models"]) do
        :ok -> errors
        {:error, error} -> [error | errors]
      end

    if errors == [] do
      {:ok, config}
    else
      {:error, Enum.join(errors, "; ")}
    end
  end

  defp validate_models(nil), do: {:error, "missing 'models' section"}
  defp validate_models(models) when not is_list(models), do: {:error, "models must be a list"}

  defp validate_models(models) do
    Enum.reduce_while(models, :ok, fn model, :ok ->
      case validate_model_entry(model) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_model_entry(entry) when is_map(entry) and is_map_key(entry, "models"),
    do: validate_model_group(entry)

  defp validate_model_entry(_), do: {:error, "model entry must define a 'models' group"}

  defp validate_model_group(group) do
    with :ok <- validate_group_provider(group["provider"]),
         :ok <- validate_group_models(group["models"]),
         :ok <- validate_optional_keys(group) do
      :ok
    end
  end

  defp validate_group_provider(provider) when is_binary(provider) and byte_size(provider) > 0,
    do: :ok

  defp validate_group_provider(_), do: {:error, "model group missing or invalid 'provider'"}

  defp validate_group_models(models) when is_list(models) do
    Enum.reduce_while(models, :ok, fn child, :ok ->
      case validate_group_child(child) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_group_models(_), do: {:error, "model group missing or invalid 'models'"}

  defp validate_group_child(child) when is_binary(child) do
    case String.split(child, ":", parts: 2) do
      [""] -> {:error, "model shorthand must be '<name>:<model>' or '<model>'"}
      ["", _] -> {:error, "model shorthand must be '<name>:<model>' or '<model>'"}
      [_, ""] -> {:error, "model shorthand must be '<name>:<model>' or '<model>'"}
      _ -> :ok
    end
  end

  defp validate_group_child(child) when is_map(child) do
    if Map.has_key?(child, "provider") or Map.has_key?(child, "keys") do
      {:error, "model group child must not define 'provider' or 'keys'"}
    else
      with :ok <- validate_model_id(child["model"]),
           :ok <- validate_optional_name(child) do
        :ok
      end
    end
  end

  defp validate_group_child(_), do: {:error, "model group child must be a mapping or string"}

  defp validate_model_id(model) when is_binary(model) and byte_size(model) > 0, do: :ok
  defp validate_model_id(_), do: {:error, "model entry missing or invalid 'model'"}

  defp validate_optional_name(entry) do
    case Map.fetch(entry, "name") do
      :error -> :ok
      {:ok, name} when is_binary(name) and byte_size(name) > 0 -> :ok
      {:ok, _} -> {:error, "model entry has invalid 'name'"}
    end
  end

  defp validate_optional_keys(entry) do
    case Map.fetch(entry, "keys") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, keys} when is_list(keys) -> :ok
      {:ok, _} -> {:error, "model entry has invalid 'keys'"}
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
        |> Map.put("fallbacks", normalize_fallbacks(config["fallbacks"]))
        |> Map.put("settings", normalize_settings(config["settings"]))

      {:ok, config}
    end
  end

  defp normalize_provider_list(list) when is_list(list), do: list
  defp normalize_provider_list(nil), do: []

  defp normalize_model_list(list) when is_list(list) do
    Enum.flat_map(list, fn %{"models" => models} = group ->
      Enum.map(models, &normalize_group_child(&1, group["provider"], Map.get(group, "keys")))
    end)
  end

  defp normalize_model_list(nil), do: []

  defp normalize_group_child(child, provider, keys) when is_map(child) do
    %{
      "name" => Map.get(child, "name"),
      "provider" => provider,
      "model" => child["model"],
      "keys" => keys
    }
  end

  defp normalize_group_child(child, provider, keys) do
    {name, model} = normalize_group_model_string(child)
    %{"name" => name, "provider" => provider, "model" => model, "keys" => keys}
  end

  defp normalize_group_model_string(child) do
    case String.split(child, ":", parts: 2) do
      [model] -> {model, model}
      [name, model] -> {name, model}
    end
  end

  defp normalize_key_list(list) when is_list(list), do: list
  defp normalize_key_list(nil), do: []

  # Fallbacks as a map: %{"gpt-4o" => ["claude-sonnet"], "*" => ["gpt-4o-mini"]}
  defp normalize_fallbacks(nil), do: %{}
  defp normalize_fallbacks(map) when is_map(map), do: map
  defp normalize_fallbacks(_), do: %{}

  defp normalize_settings(nil), do: %{"cooldown_seconds" => @default_cooldown_seconds}

  defp normalize_settings(settings) when is_map(settings) do
    %{"cooldown_seconds" => normalize_cooldown(settings["cooldown_seconds"])}
  end

  defp normalize_settings(_), do: %{"cooldown_seconds" => @default_cooldown_seconds}

  defp normalize_cooldown(n) when is_integer(n) and n > 0, do: n
  defp normalize_cooldown(n) when is_integer(n), do: 0
  defp normalize_cooldown(_), do: @default_cooldown_seconds

  defp enrich_providers(providers) do
    providers
    |> Enum.map(fn p ->
      type = String.to_atom(p["type"])

      case LLMDB.provider(type) do
        {:ok, provider_meta} ->
          {:ok,
           %{
             name: p["name"],
             type: type,
             api_key: p["api_key"],
             client_id: p["client_id"],
             runtime: provider_meta.runtime,
             base_url:
               (provider_meta.runtime && provider_meta.runtime.base_url) ||
                 provider_meta.base_url
           }}

        :error ->
          {:error, "unknown provider type '#{p["type"]}' for provider '#{p["name"]}'"}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, p}, {:ok, acc} -> {:cont, {:ok, [p | acc]}}
      {:error, _} = err, _ -> {:halt, err}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp enrich_models(models, providers) do
    provider_map = Map.new(providers, &{&1.name, &1})

    models
    |> Enum.map(fn m ->
      provider = provider_map[m["provider"]]

      if is_nil(provider) do
        name = m["name"] || m["model"]
        {:error, "model '#{name}' references unknown provider '#{m["provider"]}'"}
      else
        model_id = m["model"]
        upstream_model = resolve_upstream_model(provider.type, model_id)
        name = m["name"] || model_id

        {context, output_limit, path} =
          case LLMDB.model({provider.type, upstream_model}) do
            {:ok, md} ->
              path = get_in(md.execution, [:text, :path])
              {md.limits.context, md.limits.output, path}

            _ ->
              {nil, nil, nil}
          end

        {:ok,
         %{
           name: name,
           provider_name: provider.name,
           provider_type: provider.type,
           upstream_model: upstream_model,
           keys: m["keys"],
           context: context,
           output_limit: output_limit,
           path: path
         }}
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, m}, {:ok, acc} -> {:cont, {:ok, [m | acc]}}
      {:error, _} = err, _ -> {:halt, err}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # Pass through model ID as-is. The user specifies the upstream ID
  # exactly as the provider expects it (e.g. "deepseek/deepseek-chat"
  # for OpenRouter, "gpt-4o-mini" for OpenAI).
  defp resolve_upstream_model(_provider_type, model_id), do: model_id
end
