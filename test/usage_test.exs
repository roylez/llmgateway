defmodule Llmgateway.UsageTest do
  use ExUnit.Case, async: false

  alias Llmgateway.{Deployment, Repo, Usage}
  alias Llmgateway.Usage.Entry

  setup do
    Repo.delete_all(Entry)
    :ok
  end

  defp deployment(overrides \\ []) do
    struct(
      %Deployment{
        name: "fast",
        model: "gpt-4o-mini",
        upstream_model: "gpt-4o-mini-2024",
        provider_name: "openai"
      },
      overrides
    )
  end

  defp record(deployment, usage, opts \\ []) do
    Usage.record(
      deployment,
      usage,
      Keyword.merge([requested_model: "fast", key: "work", app: "cli", stream: false], opts)
    )
  end

  describe "record/3" do
    test "stores the requested alias and the backing model with upstream tokens" do
      record(deployment(), %{"prompt_tokens" => 10, "completion_tokens" => 5})

      assert [row] = Repo.all(Entry)
      assert row.requested_model == "fast"
      assert row.served_model == "gpt-4o-mini"
      assert row.upstream_model == "gpt-4o-mini-2024"
      assert row.usage_source == "upstream"
      assert {row.prompt_tokens, row.completion_tokens, row.total_tokens} == {10, 5, 15}
    end

    test "treats a missing upstream usage as NULL tokens with source none" do
      record(deployment(), nil)

      assert [row] = Repo.all(Entry)
      assert row.usage_source == "none"
      assert {row.prompt_tokens, row.completion_tokens, row.total_tokens} == {nil, nil, nil}
    end
  end

  describe "summarize/1" do
    test "groups by key, requested model, and served model, summing nil tokens as 0" do
      record(deployment(), %{"prompt_tokens" => 10, "completion_tokens" => 5})
      record(deployment(), %{"prompt_tokens" => 3, "completion_tokens" => 2})
      record(deployment(), nil)

      assert [summary] = Usage.summarize(%{})

      assert summary.request_count == 3
      assert summary.prompt_tokens == 13
      assert summary.completion_tokens == 7
      assert summary.total_tokens == 20
    end
  end

  describe "query/1" do
    test "treats the upper time bound as exclusive" do
      record(deployment(), nil)
      [row] = Repo.all(Entry)

      assert [] = Usage.query(%{to: row.inserted_at})
      assert [_] = Usage.query(%{from: row.inserted_at})
    end

    test "pages newest first with limit and offset" do
      for n <- 1..3 do
        record(deployment(), %{"prompt_tokens" => n, "completion_tokens" => 0})
      end

      newest_first = Usage.query(%{limit: 10}) |> Enum.map(& &1.prompt_tokens)
      assert newest_first == [3, 2, 1]

      assert Usage.query(%{limit: 1, offset: 1}) |> Enum.map(& &1.prompt_tokens) == [2]
    end
  end
end
