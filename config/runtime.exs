import Config

# Compact log format — no leading newline, no extra blank lines
config :logger, :default_formatter,
  format: "$time [$level] $message\n"

# In production, only log warnings and errors
if config_env() == :prod do
  config :logger, level: :warning
end

# Default YAML config path — override with LLMGATEWAY_CONFIG_PATH env var
config :llmgateway,
  config_path: System.get_env("LLMGATEWAY_CONFIG_PATH") || ".config/config.yaml"
