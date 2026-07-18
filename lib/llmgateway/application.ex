defmodule Llmgateway.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config_path = Application.get_env(:llmgateway, :config_path, "config/config.yaml")

    children =
      if File.exists?(config_path) do
        case Llmgateway.Config.load(config_path) do
          {:ok, config} ->
            auth_servers = github_device_servers(config)
            router = [{Llmgateway.Router, config}]
            server = maybe_start_server(config)
            auth_servers ++ router ++ server

          {:error, reason} ->
            Logger.warning("Failed to load config from #{config_path}: #{inspect(reason)}")
            []
        end
      else
        Logger.warning("Config file #{config_path} not found — starting without router")
        []
      end

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
    config["providers"]
    |> Enum.filter(fn p -> p.type == :github_copilot end)
    |> Enum.map(fn p ->
      name = :"github_device_#{p.name}"
      opts = [provider_name: p.name, name: name]

      Supervisor.child_spec(
        {Llmgateway.Auth.GitHubDevice, opts},
        id: name
      )
    end)
  end
end
