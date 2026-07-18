defmodule Llmgateway.Convert do
  @moduledoc """
  Dispatches API format conversion based on provider type.

  The proxy's canonical format is OpenAI chat/completions.
  This module converts to/from provider-native formats as needed.
  """

  alias Llmgateway.Convert.{OpenAIToAnthropic, AnthropicToOpenAI}
  alias Llmgateway.Deployment

  @doc """
  Convert an OpenAI-format request body to the provider's native format.

  Returns `{converted_body, warnings}` where warnings lists any dropped params.
  """
  def to_provider(%Deployment{provider_type: :anthropic}, body) do
    OpenAIToAnthropic.convert_request(body)
  end

  def to_provider(%Deployment{}, body) do
    {body, []}
  end

  @doc """
  Convert a provider's native response to OpenAI format.
  """
  def to_canonical(%Deployment{provider_type: :anthropic}, body) do
    AnthropicToOpenAI.convert_response(body)
  end

  def to_canonical(%Deployment{}, body) do
    body
  end

  @doc """
  Convert a provider's native SSE stream event to OpenAI SSE format.
  """
  def stream_event_to_canonical(%Deployment{provider_type: :anthropic}, event) do
    AnthropicToOpenAI.convert_stream_event(event)
  end

  def stream_event_to_canonical(%Deployment{}, event) do
    {:ok, event}
  end
end
