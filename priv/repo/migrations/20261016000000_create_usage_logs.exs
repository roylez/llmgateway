defmodule Llmgateway.Repo.Migrations.CreateUsageLogs do
  use Ecto.Migration

  def change do
    create table(:usage_logs) do
      add :key_name, :string
      add :app, :string, null: false
      add :requested_model, :string, null: false
      add :served_model, :string, null: false
      add :upstream_model, :string, null: false
      add :provider_name, :string, null: false
      add :stream, :boolean, null: false
      add :usage_source, :string, null: false
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :total_tokens, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:usage_logs, [:inserted_at])
    create index(:usage_logs, [:key_name, :inserted_at])
    create index(:usage_logs, [:requested_model])
  end
end
