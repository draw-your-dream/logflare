defmodule Logflare.LogsTest do
  @moduledoc false
  use Logflare.DataCase
  alias Logflare.{Logs, Lql}

  setup do
    Logflare.Sources.Counters
    |> stub(:incriment, fn v -> v end)

    Logflare.SystemMetrics.AllLogsLogged
    |> stub(:incriment, fn v -> v end)

    :ok
  end

  describe "ingest input" do
    setup do
      [source: insert(:source, user: build(:user))]
    end

    test "empty list", %{source: source} do
      Logs
      |> Mimic.reject(:broadcast, 1)

      assert :ok = Logs.ingest_logs([], source)
    end

    test "message key gets converted to event_message", %{source: source} do
      Logs
      |> expect(:broadcast, 1, fn le ->
        assert %{"event_message" => "testing 123"} = le.body
        assert Map.keys(le.body) |> length() == 3

        le
      end)

      batch = [
        %{"message" => "testing 123"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "top level keys", %{source: source} do
      Logs
      |> expect(:broadcast, 1, fn le ->
        assert %{"event_message" => "testing 123", "other" => 123} = le.body
        assert Map.keys(le.body) |> length() == 4

        le
      end)

      batch = [
        %{"event_message" => "testing 123", "other" => 123}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "non-map value for metadata key", %{source: source} do
      Logs
      |> expect(:broadcast, 1, fn le ->
        assert %{"metadata" => "some_value"} = le.body
        le
      end)

      batch = [
        %{"event_message" => "any", "metadata" => "some_value"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end
  end

  describe "ingest rules/filters" do
    setup do
      user = insert(:user)
      source = insert(:source, user: user)
      target = insert(:source, user: user)
      [source: source, target: target, user: user]
    end

    test "drop filter", %{user: user} do
      {:ok, lql_filters} = Lql.Parser.parse("testing", TestUtils.default_bq_schema())

      source =
        insert(:source, user: user, drop_lql_string: "testing", drop_lql_filters: lql_filters)

      Logs
      |> Mimic.reject(:broadcast, 1)

      batch = [
        %{"event_message" => "testing 123"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "no rules", %{source: source} do
      Logs
      |> expect(:broadcast, 2, fn le -> le end)

      batch = [
        %{"event_message" => "routed"},
        %{"event_message" => "routed testing 123"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "lql", %{source: source, target: target} do
      insert(:rule, lql_string: "testing", sink: target.token, source_id: source.id)
      source = source |> Repo.preload(:rules, force: true)

      Logs
      |> expect(:broadcast, 3, fn le -> le end)

      batch = [
        %{"event_message" => "not routed"},
        %{"event_message" => "testing 123"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "regex", %{source: source, target: target} do
      insert(:rule, regex: "routed123", sink: target.token, source_id: source.id)
      source = source |> Repo.preload(:rules, force: true)

      Logs
      |> expect(:broadcast, 3, fn le -> le end)

      batch = [
        %{"event_message" => "not routed"},
        %{"event_message" => "routed123"}
      ]

      assert :ok = Logs.ingest_logs(batch, source)
    end

    test "routing depth is max 1 level", %{user: user, source: source, target: target} do
      other_target = insert(:source, user: user)
      insert(:rule, lql_string: "testing", sink: target.token, source_id: source.id)
      insert(:rule, lql_string: "testing", sink: other_target.token, source_id: target.id)
      source = source |> Repo.preload(:rules, force: true)

      Logs
      |> expect(:broadcast, 2, fn le -> le end)

      assert :ok = Logs.ingest_logs([%{"event_message" => "testing 123"}], source)
    end
  end
end
