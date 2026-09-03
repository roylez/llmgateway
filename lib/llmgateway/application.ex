defmodule Llmgateway.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config_path = Application.get_env(:llmgateway, :config_path, ".config/config.yaml")

    # Boot policy: fail loudly when the config is missing or invalid.
    # A gateway without a validated config cannot serve traffic, so
    # starting an empty (or degraded) supervisor would only hide the
    # failure. The config loads once at boot; hot reload is out of scope.
    {:ok, config} =
      case Llmgateway.Config.load(config_path) do
        {:ok, config} ->
          {:ok, config}

        {:error, reason} ->
          raise "invalid config at #{config_path}: #{inspect(reason)}"
      end

    Llmgateway.Telemetry.attach_default_logger()

    children =
      [
        Llmgateway.ProviderRegistry,
        {Llmgateway.Runtime, config},
        Llmgateway.Cooldown.child_spec(window_ms: cooldown_ms(config))
      ] ++
        github_device_servers(config) ++
        [{Llmgateway.Router, config}, validation_task(config)] ++ server_children(config)

    opts = [strategy: :one_for_one, name: Llmgateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Delayed Copilot model validation as a supervised task: runs once
  # (restart: :transient) after the auth servers and router are up.
  defp validation_task(config) do
    %{
      id: :copilot_model_validation,
      start: {Task, :start_link, [fn -> validate_copilot_models(config) end]},
      restart: :transient
    }
  end

  defp server_children(config) do
    port = get_in(config, ["server", "port"])

    if port do
      Logger.info("Starting HTTP server on port #{port}")
      [{Bandit, plug: Llmgateway.Server, port: port}]
    else
      []
    end
  end

  defp cooldown_ms(config) do
    (get_in(config, ["settings", "cooldown_seconds"]) || 0) * 1000
  end

  defp github_device_servers(config) do
    data_dir = get_in(config, ["server", "data_dir"])

    config["providers"]
    |> Enum.filter(fn p -> p.type == :github_copilot end)
    |> Enum.map(fn p ->
      opts = [
        provider_name: p.name,
        data_dir: data_dir,
        name: {:via, Registry, {Llmgateway.ProviderRegistry, p.name}}
      ]

      Supervisor.child_spec(
        {Llmgateway.Auth.GitHubDevice, opts},
        id: {:github_device, p.name}
      )
    end)
  end

  defp validate_copilot_models(config) do
    Process.sleep(5_000)
    copilot_providers = Enum.filter(config["providers"], &(&1.type == :github_copilot))

    for provider <- copilot_providers do
      case Llmgateway.ProviderRegistry.github_device(provider.name) do
        nil ->
          :ok

        server ->
          known = Llmgateway.Auth.GitHubDevice.list_known_models(server)

          if known != [] do
            for model <- config["models"], model.provider_name == provider.name do
              unless model.upstream_model in known do
                suggestion = suggest_similar(model.upstream_model, known)
                hint = if suggestion, do: " Did you mean '#{suggestion}'?", else: ""

                Logger.warning(
                  "[config] Model '#{model.name}' uses upstream '#{model.upstream_model}' " <>
                    "which is not available on GitHub Copilot.#{hint}"
                )
              end
            end
          end
      end
    end
  end

  defp suggest_similar(target, candidates) do
    target_lower = String.downcase(target)

    candidates
    |> Enum.filter(fn c ->
      c_lower = String.downcase(c)
      String.contains?(c_lower, target_lower) or String.contains?(target_lower, c_lower)
    end)
    |> List.first()
  end
end
