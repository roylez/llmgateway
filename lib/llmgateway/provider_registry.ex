defmodule Llmgateway.ProviderRegistry do
  @moduledoc """
  Registry of per-provider runtime processes, keyed by provider name (a
  user-controlled config string) instead of dynamically-created atoms.

  Hosting process names as atoms would leak memory across arbitrary config
  reloads and risk atom-table exhaustion, so GitHub device servers are
  registered here keyed by their plain provider name string.
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Resolve the GitHub device server for a provider name.

  Returns a server reference suitable for passing to `GitHubDevice`
  functions, or `nil` when no server is registered under that name.
  """
  def github_device(provider_name) do
    case Registry.lookup(__MODULE__, provider_name) do
      [{_pid, _}] -> {:via, Registry, {__MODULE__, provider_name}}
      [] -> nil
    end
  end
end
