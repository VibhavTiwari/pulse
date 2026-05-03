defmodule PulseWeb.Api.ReviewInboxController do
  use PulseWeb, :controller

  alias Pulse.ReviewInbox
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(
      conn,
      Enum.map(ReviewInbox.list_suggestions(workspace_id, params), &JSONHelpers.review_item/1)
    )
  end

  def show(conn, %{"workspace_id" => workspace_id, "type" => type, "id" => id}) do
    json(conn, JSONHelpers.review_item(ReviewInbox.get_suggestion!(workspace_id, type, id)))
  end

  def update(conn, %{"workspace_id" => workspace_id, "type" => type, "id" => id} = params) do
    case ReviewInbox.update_suggestion(workspace_id, type, id, params) do
      {:ok, _record} ->
        json(conn, JSONHelpers.review_item(ReviewInbox.get_suggestion!(workspace_id, type, id)))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def accept(conn, %{"workspace_id" => workspace_id, "type" => type, "id" => id}) do
    case ReviewInbox.accept_suggestion(workspace_id, type, id) do
      {:ok, record} ->
        json(
          conn,
          JSONHelpers.review_item(%{type: type, id: record.id, record: record, incomplete: false})
        )

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def reject(conn, %{"workspace_id" => workspace_id, "type" => type, "id" => id}) do
    case ReviewInbox.reject_suggestion(workspace_id, type, id) do
      {:ok, record} ->
        json(
          conn,
          JSONHelpers.review_item(%{type: type, id: record.id, record: record, incomplete: false})
        )

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end
end
