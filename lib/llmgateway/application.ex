defmodule Llmgateway.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config_path = Application.get_env(:llmgateway, :config_path, ".config/config.yaml")

    children =
      if File.exists?(config_path) do
        case Llmgateway.Config.load(config_path) do
          {:ok, config} ->
            auth_servers = github_device_servers(config)
            router = [{Llmgateway.Router, config}]
            server = maybe_start_server(config)

            # Validate copilot model IDs after /models list is fetched
            Task.start(fn ->
              Process.sleep(5_000)
              validate_copilot_models(config)
            end)

            auth_servers ++ router ++ server

          {:error, reason} ->
            Logger.warning("Failed to load config from #{config_path}: #{inspect(reason)}")
            []
        end
      else
        Logger.warning("Config file #{config_path} not found — starting without router")
        []
      end


    Llmgateway.Telemetry.attach_default_logger()

    opts = [strategy: :one_for_one, name: Llmgateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_server(config) do
    port = get_in(config, ["server", "port"])

    if port do
      Logger.info("Starting HTTP server on port #{port}")
      [{Bandit, plug: Llmgateway.Server, port: port}]
    else
      []
    end
  end

  defp github_device_servers(config) do
    data_dir = get_in(config, ["server", "data_dir"])

    config["providers"]
    |> Enum.filter(fn p -> p.type == :github_copilot end)
    |> Enum.map(fn p ->
      name = :"github_device_#{p.name}"
      opts = [provider_name: p.name, data_dir: data_dir, name: name]

      Supervisor.child_spec(
        {Llmgateway.Auth.GitHubDevice, opts},
        id: name
      )
    end)
  end

  defp validate_copilot_models(config) do
    copilot_providers = Enum.filter(config["providers"], &(&1.type == :github_copilot))

    for provider <- copilot_providers do
      server_name = :"github_device_#{provider.name}"

      if Process.whereis(server_name) do
        known = Llmgateway.Auth.GitHubDevice.list_known_models(server_name)

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
