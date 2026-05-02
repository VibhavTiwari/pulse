defmodule PulseWeb.Api.RecordController do
  use PulseWeb, :controller

  alias Pulse.Records
  alias PulseWeb.Api.JSONHelpers

  @plural %{
    "decisions" => "decision",
    "commitments" => "commitment",
    "risks" => "risk",
    "meetings" => "meeting",
    "briefs" => "brief"
  }

  def index(conn, %{"workspace_id" => workspace_id, "collection" => collection} = params) do
    type = Map.fetch!(@plural, collection)
    records = Records.list(type, workspace_id, params)
    json(conn, Enum.map(records, &JSONHelpers.record(&1, type)))
  end

  def create(conn, %{"workspace_id" => workspace_id, "collection" => collection} = params) do
    type = Map.fetch!(@plural, collection)

    case Records.create(type, workspace_id, params) do
      {:ok, record} ->
        json(conn, JSONHelpers.record(record, type))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"type" => type, "id" => id}) do
    type = normalize_type(type)
    json(conn, JSONHelpers.record(Records.get!(type, id), type))
  end

  def update(conn, %{"type" => type, "id" => id} = params) do
    type = normalize_type(type)
    record = Records.get!(type, id)

    case Records.update(type, record, params) do
      {:ok, record} ->
        json(conn, JSONHelpers.record(record, type))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def accept(conn, %{"type" => type, "id" => id}) do
    transition(conn, normalize_type(type), id, "accepted")
  end

  def reject(conn, %{"type" => type, "id" => id}) do
    transition(conn, normalize_type(type), id, "rejected")
  end

  def link(conn, %{
        "parent_type" => parent_type,
        "parent_id" => parent_id,
        "child_type" => child_type,
        "child_id" => child_id
      }) do
    parent_type = normalize_type(parent_type)
    child_type = normalize_type(child_type)

    case Records.link(parent_type, parent_id, child_type, child_id) do
      {:ok, record} -> json(conn, JSONHelpers.record(record, parent_type))
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  defp transition(conn, type, id, state) do
    record = Records.get!(type, id)

    case Records.transition_state(type, record, state) do
      {:ok, record} ->
        json(conn, JSONHelpers.record(record, type))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  defp normalize_type(type), do: Map.get(@plural, type, type)
end
