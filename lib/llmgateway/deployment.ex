defmodule Llmgateway.Deployment do
  @moduledoc """
  A resolved deployment ready for execution.

  Combines a model config with its resolved provider runtime metadata.
  """

  defstruct [
    # local alias, e.g. "deepseek-v4-flash"
    :name,
    # named provider reference, e.g. "openrouter"
    :provider_name,
    # llm_db provider atom, e.g. :openrouter
    :provider_type,
    # upstream model ID, e.g. "deepseek/deepseek-v4-flash"
    :upstream_model,
    # resolved API key string or nil
    :api_key,
    # base URL from llm_db provider metadata + config overrides
    :base_url,
    # context limit from llm_db model metadata
    :context,
    # output limit from llm_db model metadata
    :output_limit
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
