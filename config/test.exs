import Config

# Boot a minimal valid config so the application starts cleanly under
# `mix test` (boot fails loudly on invalid config). Individual tests
# manage their own Router/Runtime instances.
config :llmgateway, config_path: "test/fixtures/app_boot.yaml"
