# Stop the application to prevent it from managing Router/Bandit
# Tests start their own Router instances
Application.stop(:llmgateway)

# Tests start their own Router instances; the provider registry backs the
# runtime references the Router resolves on every deployment build.
{:ok, _} = Registry.start_link(keys: :unique, name: Llmgateway.ProviderRegistry)

ExUnit.start()
