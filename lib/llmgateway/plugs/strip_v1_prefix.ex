defmodule Llmgateway.Plugs.StripV1Prefix do
  @moduledoc """
  Strips the `/v1` and `/v2` prefix from request paths so that both
  `/v1/models` and `/models` match the same route in Plug.Router.
  """
  @behaviour Plug

  def init(_opts), do: nil

  def call(conn, _opts) do
    case conn.path_info do
      ["v1" | rest] -> %{conn | path_info: rest}
      ["v2" | rest] -> %{conn | path_info: rest}
      _ -> conn
    end
  end
end
