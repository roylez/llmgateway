defmodule Llmgateway.Repo do
  use Ecto.Repo,
    otp_app: :llmgateway,
    adapter: Ecto.Adapters.SQLite3
end
