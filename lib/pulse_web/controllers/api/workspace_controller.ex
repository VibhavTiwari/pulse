defmodule PulseWeb.Api.WorkspaceController do
  use PulseWeb, :controller
  alias Pulse.Workspaces
  alias PulseWeb.Api.JSONHelpers

  def index(conn, _params) do
    json(conn, Enum.map(Workspaces.list_workspaces(), &JSONHelpers.workspace/1))
  end

  def create(conn, params) do
    case Workspaces.create_workspace(params) do
      {:ok, workspace} ->
        json(conn, JSONHelpers.workspace(workspace))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    json(conn, JSONHelpers.workspace(Workspaces.get_workspace!(id)))
  end
end
