defmodule Llmgateway.Deployment do
  @moduledoc """
  A resolved deployment ready for execution.

  Combines a model config with its resolved provider runtime metadata.
  """

  defstruct [
    :name,           # local alias, e.g. "deepseek-v4-flash"
    :provider_name,  # named provider reference, e.g. "openrouter"
    :provider_type,  # llm_db provider atom, e.g. :openrouter
    :upstream_model, # upstream model ID, e.g. "deepseek/deepseek-v4-flash"
    :api_key,        # resolved API key string or nil
    :base_url,       # base URL from llm_db provider metadata + config overrides
    :context,        # context limit from llm_db model metadata
    :output_limit    # output limit from llm_db model metadata
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          provider_name: String.t(),
          provider_type: atom(),
          upstream_model: String.t(),
          api_key: String.t() | nil,
          base_url: String.t(),
          context: non_neg_integer(),
          output_limit: non_neg_integer()
        }
end