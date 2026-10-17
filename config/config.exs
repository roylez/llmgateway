import Config

import_config "#{config_env()}.exs"

config :llmgateway, Llmgateway.Repo,
  foreign_keys: :on,
  # https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html#module-limitations-and-caveats
  journal_mode: :wal,
  synchronous: :normal,
  custom_pragmas: [mmap_size: 1_049_190_400],
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
  temp_store: :memory,
  pool_size: 5

config :llmgateway, ecto_repos: [Llmgateway.Repo]
