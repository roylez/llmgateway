defmodule Llmgateway.Usage.Entry do
  @moduledoc "One recorded successful request in `usage_logs`."

  use Ecto.Schema
  import Ecto.Changeset

  @fields [
    :key_name,
    :app,
    :requested_model,
    :served_model,
    :upstream_model,
    :provider_name,
    :stream,
    :usage_source,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens
  ]

  @required [
    :app,
    :requested_model,
    :served_model,
    :upstream_model,
    :provider_name,
    :stream,
    :usage_source
  ]

  schema "usage_logs" do
    field(:key_name, :string)
    field(:app, :string)
    field(:requested_model, :string)
    field(:served_model, :string)
    field(:upstream_model, :string)
    field(:provider_name, :string)
    field(:stream, :boolean)
    field(:usage_source, :string)
    field(:prompt_tokens, :integer)
    field(:completion_tokens, :integer)
    field(:total_tokens, :integer)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
