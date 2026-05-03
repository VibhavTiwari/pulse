defmodule PulseWeb.Api.MeetingController do
  use PulseWeb, :controller

  alias Pulse.Meetings
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Meetings.list_meetings(workspace_id, params), &JSONHelpers.meeting/1))
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Meetings.create_meeting(workspace_id, params) do
      {:ok, meeting} ->
        json(conn, JSONHelpers.meeting(meeting))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.meeting(Meetings.get_meeting!(workspace_id, id)))
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    meeting = Meetings.get_meeting!(workspace_id, id)

    case Meetings.update_meeting(meeting, params) do
      {:ok, meeting} ->
        json(conn, JSONHelpers.meeting(meeting))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def prep(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.meeting_prep(Meetings.get_prep(workspace_id, id)))
  end

  def refresh_prep(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.meeting_prep(Meetings.refresh_prep(workspace_id, id)))
  end

  def link_decision(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "decision_id" => decision_id
      }) do
    meeting = Meetings.get_meeting!(workspace_id, id)

    case Meetings.link_decision(meeting, decision_id) do
      {:ok, meeting} -> json(conn, JSONHelpers.meeting(meeting))
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def unlink_decision(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "decision_id" => decision_id
      }) do
    meeting = Meetings.get_meeting!(workspace_id, id)
    {:ok, meeting} = Meetings.unlink_decision(meeting, decision_id)
    json(conn, JSONHelpers.meeting(meeting))
  end

  def link_commitment(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "commitment_id" => commitment_id
      }) do
    meeting = Meetings.get_meeting!(workspace_id, id)

    case Meetings.link_commitment(meeting, commitment_id) do
      {:ok, meeting} -> json(conn, JSONHelpers.meeting(meeting))
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def unlink_commitment(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "commitment_id" => commitment_id
      }) do
    meeting = Meetings.get_meeting!(workspace_id, id)
    {:ok, meeting} = Meetings.unlink_commitment(meeting, commitment_id)
    json(conn, JSONHelpers.meeting(meeting))
  end
end
