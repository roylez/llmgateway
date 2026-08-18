defmodule Llmgateway.ClientIdentity do
  @moduledoc """
  Resolves the calling application from explicit request metadata.

  `X-LiteLLM-Agent-Id` is optional application metadata. Add an inferred
  fingerprint only after a client proves a stable, client-specific signature.
  A runtime User-Agent alone is not application identity.
  """

  @spec app(Plug.Conn.t()) :: String.t()
  def app(conn) do
    case Plug.Conn.get_req_header(conn, "x-litellm-agent-id") do
      [agent_id | _] when agent_id != "" -> agent_id
      _ -> "unknown"
    end
  end
end
