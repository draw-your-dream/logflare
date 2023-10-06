defmodule LogflareWeb.AlertsLiveTest do
  use LogflareWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Logflare.Backends.Adaptor.WebhookAdaptor
  alias Logflare.Backends.Adaptor.SlackAdaptor

  @update_attrs %{
    name: "some updated name",
    description: "some updated description",
    cron: "2 * * * * *",
    query: "select another from `my-source`",
    slack_hook_url: "some updated slack_hook_url",
    webhook_notification_url: "some updated webhook_notification_url"
  }

  setup %{conn: conn} do
    insert(:plan, name: "Free")
    user = insert(:user)
    conn = login_user(conn, user)
    [user: user, conn: conn]
  end

  defp create_alert_query(%{user: user}) do
    %{alert_query: insert(:alert, user_id: user.id)}
  end

  describe "Index" do
    setup [:create_alert_query]

    test "lists all alert_queries", %{conn: conn, alert_query: alert_query} do
      {:ok, view, html} = live(conn, Routes.alerts_path(conn, :index))
      assert html =~ alert_query.name
      assert html =~ "Alerts"
      # link to show
      view
      |> element("ul li a", alert_query.name)
      |> render_click()

      assert_patched(view, "/alerts/#{alert_query.id}")
      assert has_element?(view, "h1,h2,h3,h4,h5", alert_query.name)
      assert has_element?(view, "p", alert_query.description)
      assert has_element?(view, "code", alert_query.query)
    end

    test "saves new alert_query", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :index))

      assert view
             |> element("a", "New alert")
             |> render_click() =~ ~r/\~\/.+alerts.+\/new/

      assert_patch(view, "/alerts/new")

      new_query = "select current_timestamp() as my_time"

      assert view
             |> element("form#alert")
             |> render_submit(%{
               alert: %{
                 description: "some description",
                 name: "some alert query",
                 query: new_query,
                 cron: "0 0 * * * *",
                 language: "bq_sql"
               }
             }) =~ "Successfully created alert"

      # redirected to :show
      assert assert_patch(view) =~ ~r/\/alerts\/\S+/
      html = render(view)
      assert html =~ "some description"
      assert html =~ "some alert query"
      assert html =~ new_query
    end

    test "saves new alert_query with errors, shows flash message", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :index))

      assert view
             |> element("a", "New alert")
             |> render_click() =~ ~r/\~\/.+alerts.+\/new/

      assert_patch(view, "/alerts/new")

      assert view
             |> element("form#alert")
             |> render_submit(%{
               alert: %{
                 description: "some description",
                 name: "some alert query",
                 query: "select current_timestamp() from `error query",
                 cron: "0 0 * * * *",
                 language: "bq_sql"
               }
             }) =~ "Could not create alert"

      assert view |> has_element?("form#alert")
    end

    test "update alert_query", %{conn: conn, alert_query: alert_query} do
      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :index))

      view
      |> element("li a", alert_query.name)
      |> render_click()

      view
      |> element("a", "edit")
      |> render_click()

      view
      |> element("form#alert")
      |> render_submit(%{
        alert: @update_attrs
      }) =~ "updated successfully"

      html = render(view)
      assert html =~ @update_attrs.name
      assert html =~ @update_attrs.query
      refute html =~ alert_query.name
      refute html =~ alert_query.query
    end

    test "deletes alert_query in listing", %{conn: conn, alert_query: alert_query} do
      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :edit, alert_query))

      assert view
             |> element("button", "Delete")
             |> render_click() =~ "has been deleted"

      assert_patch(view, "/alerts")
      refute view |> has_element?("li", alert_query.name)
    end

    test "remove slack hook", %{conn: conn, alert_query: alert_query} do
      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :show, alert_query))

      assert view
             |> element("button", "Remove Slack")
             |> render_click() =~ "Slack notifications have been removed"

      assert view
             |> element("img[alt='Add to Slack']")
             |> has_element?()
    end
  end

  describe "running alerts" do
    setup [:create_alert_query]

    setup do
      # mock goth behaviour
      Goth
      |> stub(:fetch, fn _mod -> {:ok, %Goth.Token{token: "auth-token"}} end)

      WebhookAdaptor.Client
      |> stub(:send, fn _, _ -> %Tesla.Env{} end)

      SlackAdaptor.Client
      |> stub(:send, fn _, _ -> %Tesla.Env{} end)

      :ok
    end

    test "manual alert trigger - notification sent", %{conn: conn, alert_query: alert_query} do
      GoogleApi.BigQuery.V2.Api.Jobs
      |> expect(:bigquery_jobs_query, 1, fn _conn, _proj_id, _opts ->
        {:ok, TestUtils.gen_bq_response([%{"testing" => "results-123"}])}
      end)

      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :show, alert_query))

      assert view
             |> element("button", "Manual trigger")
             |> render_click() =~ "Alert has been triggered. Notifications sent!"
    end

    test "manual alert trigger - notification not sent", %{conn: conn, alert_query: alert_query} do
      GoogleApi.BigQuery.V2.Api.Jobs
      |> expect(:bigquery_jobs_query, 1, fn _conn, _proj_id, _opts ->
        {:ok, TestUtils.gen_bq_response([])}
      end)

      {:ok, view, _html} = live(conn, Routes.alerts_path(conn, :show, alert_query))

      assert view
             |> element("button", "Manual trigger")
             |> render_click() =~
               "Alert has been triggered. No results from query, notifications not sent!"
    end
  end
end
