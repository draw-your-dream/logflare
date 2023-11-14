defmodule Logflare.Source.RecentLogsServer do
  @moduledoc """
  Manages the individual table for the source. Limits things in the table to 1000. Manages TTL for
  things in the table. Handles loading the table from the disk if found on startup.
  """
  use TypedStruct
  use GenServer

  alias Logflare.Billing.Plan
  alias Logflare.TaskSupervisor

  alias Logflare.Source.BigQuery.Schema
  alias Logflare.Source.BigQuery.Pipeline
  alias Logflare.Source.BigQuery.BufferCounter

  alias Logflare.Source.EmailNotificationServer
  alias Logflare.Source.TextNotificationServer
  alias Logflare.Source.WebhookNotificationServer
  alias Logflare.Source.SlackHookServer
  alias Logflare.Source.BillingWriter

  alias Logflare.Source.RateCounterServer, as: RCS
  alias Logflare.LogEvent, as: LE
  alias Logflare.Source
  alias Logflare.Users
  alias Logflare.Billing
  alias Logflare.Sources
  alias Logflare.Logs.SearchQueryExecutor
  alias Logflare.PubSubRates
  alias Logflare.Cluster
  alias __MODULE__, as: RLS

  require Logger

  typedstruct do
    field(:source_id, atom(), enforce: true)
    field(:notifications_every, integer(), default: 60_000)
    field(:inserts_since_boot, integer(), default: 0)
    field(:bigquery_project_id, atom())
    field(:bigquery_dataset_id, binary())
    field(:source, struct())
    field(:user, struct())
    field(:plan, Plan.t())
    field(:total_cluster_inserts, integer(), default: 0)
    field(:recent, list(), default: LQueue.new(100))
    field(:billing_last_node_count, integer(), default: 0)
    field(:latest_log_event, LE.t())
  end

  @touch_timer :timer.minutes(45)
  @broadcast_every 500
  @pool_size Application.compile_env(:logflare, Logflare.PubSub)[:pool_size]

  @spec push(LE.t()) :: :ok
  def push(%LE{source: %Source{token: source_id}} = log_event) do
    case Source.Supervisor.lookup(__MODULE__, source_id) do
      {:ok, pid} -> GenServer.cast(pid, {:push, source_id, log_event})
      {:error, _} -> :ok
    end
  end

  @spec push(atom(), Logflare.LogEvent.t()) :: :ok
  def push(source_id, %LE{} = log_event) when is_atom(source_id) do
    case Source.Supervisor.lookup(__MODULE__, source_id) do
      {:ok, pid} -> GenServer.cast(pid, {:push, source_id, log_event})
      {:error, _} -> :ok
    end
  end

  def list(source_id) when is_atom(source_id) do
    case Source.Supervisor.lookup(__MODULE__, source_id) do
      {:ok, pid} ->
        {:ok, logs} = GenServer.call(pid, :list)
        logs

      {:error, _} ->
        []
    end
  end

  def list_for_cluster(source_id) when is_atom(source_id) do
    nodes = Cluster.Utils.node_list_all()

    task =
      Task.async(fn ->
        nodes
        |> Enum.map(&Task.Supervisor.async({TaskSupervisor, &1}, __MODULE__, :list, [source_id]))
        |> Task.yield_many()
        |> Enum.map(fn {%Task{pid: pid}, res} ->
          res || Task.Supervisor.terminate_child(TaskSupervisor, pid)
        end)
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task) do
      {:ok, results} ->
        results
        |> Enum.map(fn {:ok, events} -> events end)
        |> List.flatten()
        |> Enum.sort_by(& &1.body["timestamp"], &<=/2)
        |> Enum.take(-100)

      _else ->
        list(source_id)
    end
  end

  def get_latest_date(source_id) when is_atom(source_id) do
    case Source.Supervisor.lookup(__MODULE__, source_id) do
      {:ok, pid} ->
        case GenServer.call(pid, :latest_le) do
          {:ok, log_event} -> log_event.body["timestamp"]
          {:error, _reason} -> 0
        end

      {:error, _} ->
        0
    end
  end

  ## Server

  def start_link(%__MODULE__{source_id: source_id} = rls) when is_atom(source_id) do
    GenServer.start_link(__MODULE__, rls, name: Source.Supervisor.via(__MODULE__, source_id))
  end

  ## Client
  @spec init(RLS.t()) :: {:ok, RLS.t(), {:continue, :boot}}
  def init(%__MODULE__{source_id: _source_id, source: source} = rls) do
    user =
      source.user_id
      |> Users.get()
      |> Users.maybe_preload_bigquery_defaults()
      |> Users.preload_billing_account()

    plan = Billing.get_plan_by_user(user)

    rls = %{
      rls
      | bigquery_project_id: user.bigquery_project_id,
        bigquery_dataset_id: user.bigquery_dataset_id,
        user: user,
        plan: plan,
        notifications_every: source.notifications_every
    }

    # these go into separate supervisor that blocks
    children = [
      {BufferCounter, rls},
      {Schema, rls},
      {Pipeline, rls}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)

    touch()
    broadcast()

    {:ok, rls, {:continue, :boot}}
  end

  def handle_continue(:boot, rls) do
    children = [
      {RCS, rls},
      {EmailNotificationServer, rls},
      {TextNotificationServer, rls},
      {WebhookNotificationServer, rls},
      {SlackHookServer, rls},
      {SearchQueryExecutor, rls},
      {BillingWriter, rls}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)

    load_init_log_message(rls.source_id)

    Logger.info("RecentLogsServer started", source_id: rls.source_id)
    {:noreply, rls}
  end

  def handle_call(:list, _from, state) do
    recent = Enum.into(state.recent, [])
    {:reply, {:ok, recent}, state}
  end

  def handle_call(:latest_le, _from, %{latest_log_event: nil} = state) do
    {:reply, {:error, :no_log_event_yet}, state}
  end

  def handle_call(:latest_le, _from, state) do
    {:reply, {:ok, state.latest_log_event}, state}
  end

  def handle_cast({:push, _source_id, %LE{} = le}, state) do
    log_events = LQueue.push(state.recent, le)
    {:noreply, %{state | recent: log_events, latest_log_event: le}}
  end

  def handle_info({:push, _source_id, %LE{} = le}, state) do
    log_events = LQueue.push(state.recent, le)
    {:noreply, %{state | recent: log_events, latest_log_event: le}}
  end

  def handle_info({:stop_please, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(:broadcast, state) do
    {:ok, total_cluster_inserts, inserts_since_boot} = broadcast_count(state)

    broadcast()

    {:noreply,
     %{
       state
       | total_cluster_inserts: total_cluster_inserts,
         inserts_since_boot: inserts_since_boot
     }}
  end

  def handle_info(:touch, %__MODULE__{source_id: source_id} = state) do
    case Enum.into(state.recent, []) do
      [%Logflare.LogEvent{params: %{"is_system_log_event?" => true}}] ->
        touch()
        {:noreply, state}

      log_events ->
        log_event = Enum.reverse(log_events) |> hd()

        now = NaiveDateTime.utc_now()

        if NaiveDateTime.diff(now, log_event.ingested_at, :millisecond) < @touch_timer do
          Sources.Cache.get_by(token: source_id)
          |> Sources.update_source(%{log_events_updated_at: DateTime.utc_now()})
        end

        touch()
        {:noreply, state}
    end
  end

  def terminate(reason, state) do
    # Do Shutdown Stuff
    Logger.error("Going Down - #{inspect(reason)} - #{state.source_id}", %{
      source_id: state.source_id
    })

    reason
  end

  ## Private Functions
  defp broadcast_count(state) do
    current_inserts = Source.Data.get_node_inserts(state.source_id)
    last_inserts = state.inserts_since_boot

    if current_inserts > last_inserts do
      bq_inserts = Source.Data.get_bq_inserts(state.source_id)

      inserts_payload = %{Node.self() => %{node_inserts: current_inserts, bq_inserts: bq_inserts}}

      shard = :erlang.phash2(state.source_id, @pool_size)

      Phoenix.PubSub.broadcast(
        Logflare.PubSub,
        "inserts:shard-#{shard}",
        {:inserts, state.source_id, inserts_payload}
      )
    end

    current_cluster_inserts = PubSubRates.Cache.get_cluster_inserts(state.source_id)
    last_cluster_inserts = state.total_cluster_inserts

    if current_cluster_inserts > last_cluster_inserts do
      payload = %{log_count: current_cluster_inserts, source_token: state.source_id}
      Source.ChannelTopics.broadcast_log_count(payload)
    end

    {:ok, current_cluster_inserts, current_inserts}
  end

  def load_init_log_message(source_id) do
    message =
      "Initialized on node #{Node.self()}. Waiting for new events. Send some logs, then try to explore & search!"

    log_event =
      LE.make(
        %{
          "message" => message,
          "is_system_log_event?" => true
        },
        %{
          source: %Source{token: source_id}
        }
      )

    Process.send_after(self(), {:push, source_id, log_event}, 1_000)

    Source.ChannelTopics.broadcast_new(log_event)
  end

  defp touch() do
    rand = Enum.random(0..30) * :timer.minutes(1)

    every = rand + @touch_timer

    Process.send_after(self(), :touch, every)
  end

  defp broadcast() do
    Process.send_after(self(), :broadcast, @broadcast_every)
  end
end
