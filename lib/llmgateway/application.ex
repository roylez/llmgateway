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
            [{Llmgateway.Router, config}]

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
end
