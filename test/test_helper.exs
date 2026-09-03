# Stop the application to prevent it from managing Router/Bandit at startup.
# Tests start their own Router instances via start_supervised!/1, so each test
# gets a fresh, isolated state instead of racing for the globally named process.
Application.stop(:llmgateway)

# Tests start their own Router instances; the provider registry backs the
# runtime references the Router resolves on every deployment build.
{:ok, _} = Registry.start_link(keys: :unique, name: Llmgateway.ProviderRegistry)

ExUnit.start()
