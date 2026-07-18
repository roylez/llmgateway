import Config

# Compact log format — no leading newline, no extra blank lines
config :logger, :default_formatter,
  format: "$time [$level] $message\n"

# Production: info level (fallbacks, auth, lifecycle — no per-request debug)
# Dev: debug level (all requests logged)
if config_env() == :prod do
  config :logger, level: :info
else
  config :logger, level: :debug
end

# Default YAML config path — override with LLMGATEWAY_CONFIG_PATH env var
unless config_env() == :test do
  config :llmgateway,
    config_path: System.get_env("LLMGATEWAY_CONFIG_PATH") || ".config/config.yaml"
end
