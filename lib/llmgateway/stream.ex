defmodule Llmgateway.Stream do
  @moduledoc """
  SSE streaming support for LLM provider responses.

  Uses Req's `into: :self` to stream responses, parses SSE events,
  converts them to OpenAI format if needed, and yields chunks.
  """

  require Logger

  alias Llmgateway.{Auth, Convert, Convert.ResponsesAPI, Deployment}

  @doc """
  Execute a streaming request and return an enumerable of OpenAI-format SSE chunks.

  Each yielded value is a map (decoded JSON) in OpenAI chat.completion.chunk format.
  The caller should encode and forward these as SSE `data:` lines.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  def call(%Deployment{} = deployment, body, opts \\ []) do
    timeout = opts[:timeout] || 120_000

    {provider_body, _warnings} = Convert.to_provider(deployment, body)

    provider_body =
      provider_body
      |> Map.put("model", deployment.upstream_model)
      |> Map.put("stream", true)
      |> Map.delete("_llmgateway")

    base_req = Req.new(base_url: deployment.base_url, receive_timeout: timeout, retry: false)

    case Auth.add_headers(base_req, deployment) do
      {:ok, req} ->
        url = Auth.request_path(deployment)
        is_responses = (url == "/responses")

        request_body =
          if is_responses do
            ResponsesAPI.to_responses(provider_body)
          else
            provider_body
          end

        case Req.post(req, url: url, json: request_body, into: :self) do
          {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
            stream =
              resp.body
              |> to_sse_stream(resp)
              |> Stream.transform("", &buffer_sse_lines/2)
              |> Stream.flat_map(&decode_and_convert(&1, deployment, is_responses))

            {:ok, stream}

          {:ok, %Req.Response{status: status, body: body}} ->
            error_body = drain_body(body)
            {:error, classify_error(status, error_body, deployment)}

          {:error, reason} ->
            {:error, %{type: :transport_error, reason: reason, deployment: deployment.name}}
        end

      {:error, reason} ->
        {:error, %{type: :client_error, message: "Auth failed: #{inspect(reason)}", deployment: deployment.name}}
    end
  end

  # ── SSE parsing ───────────────────────────────────────────

  # Convert Req.Response.Async body into a stream of raw data binaries
  defp to_sse_stream(body, _resp) when is_struct(body, Req.Response.Async) do
    body
  end

  defp to_sse_stream(body, _resp) when is_binary(body) do
    [body]
  end

  defp to_sse_stream(body, _resp), do: body

  @doc false
  def parse_sse_lines(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.trim_leading(&1, "data: "))
  end

  # Buffer partial lines across SSE chunks
  defp buffer_sse_lines(chunk, buffer) when is_binary(chunk) do
    combined = buffer <> chunk
    lines = String.split(combined, "\n")

    # Last element may be partial — carry it as the new buffer
    {complete, [remainder]} = Enum.split(lines, -1)

    data_lines =
      complete
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))

    {data_lines, remainder}
  end

  defp decode_and_convert("[DONE]", _deployment, _is_responses), do: [:done]

  defp decode_and_convert(data, deployment, is_responses) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, event} ->
        result =
          if is_responses do
            ResponsesAPI.stream_event_to_chunk(event)
          else
            Convert.stream_event_to_canonical(deployment, event)
          end

        case result do
          {:ok, chunk} -> [chunk]
          :skip -> []
          :done -> [:done]
        end

      {:error, _} ->
        Logger.debug("Failed to decode SSE event: #{data}")
        []
    end
  end


  # ── Error helpers ─────────────────────────────────────────

  defp drain_body(body) when is_binary(body), do: body

  defp drain_body(body) do
    try do
      Enum.join(body, "")
    rescue
      _ -> ""
    end
  end

  defp classify_error(429, _body, deployment) do
    %{type: :rate_limit, status: 429, deployment: deployment.name}
  end

  defp classify_error(status, _body, deployment) when status >= 500 do
    %{type: :server_error, status: status, deployment: deployment.name}
  end

  defp classify_error(status, _body, deployment) do
    %{type: :client_error, status: status, deployment: deployment.name}
  end
end
