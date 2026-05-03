defmodule PulseWeb.Api.BriefController do
  use PulseWeb, :controller

  alias Pulse.Briefs
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Briefs.list_briefs(workspace_id, params), &JSONHelpers.brief/1))
  end

  def latest(conn, %{"workspace_id" => workspace_id}) do
    case Briefs.latest_daily_brief(workspace_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: :not_found})
      brief -> json(conn, JSONHelpers.brief(brief))
    end
  end

  def generate(conn, %{"workspace_id" => workspace_id} = params) do
    case Briefs.generate_daily_brief(workspace_id, params) do
      {:ok, brief} ->
        json(conn, JSONHelpers.brief(brief))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.brief(Briefs.get_brief!(workspace_id, id)))
  end

  def item_evidence(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "item_id" => item_id
      }) do
    json(conn, Briefs.list_item_evidence(workspace_id, id, item_id))
  end
end
