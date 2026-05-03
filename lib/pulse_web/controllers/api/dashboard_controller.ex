defmodule PulseWeb.Api.DashboardController do
  use PulseWeb, :controller

  alias Pulse.Dashboard
  alias PulseWeb.Api.JSONHelpers

  def show(conn, %{"workspace_id" => workspace_id}) do
    json(conn, JSONHelpers.dashboard(Dashboard.get(workspace_id)))
  end
end
