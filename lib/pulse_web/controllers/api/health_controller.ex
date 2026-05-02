defmodule PulseWeb.Api.HealthController do
  use PulseWeb, :controller
  alias Pulse.Workspaces

  def show(conn, _params) do
    json(conn, %{status: "ok", workspace_count: length(Workspaces.list_workspaces())})
  end
end
