import Config

# Don't start the server during tests
config :llmgateway,
  config_path: "nonexistent.yaml"
