defmodule PulseWeb.Api.EvidenceController do
  use PulseWeb, :controller
  alias Pulse.Evidence
  alias PulseWeb.Api.JSONHelpers

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Evidence.create_reference(workspace_id, params) do
      {:ok, reference} ->
        json(conn, JSONHelpers.evidence(reference))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def for_record(conn, %{"target_entity_type" => type, "target_entity_id" => id}) do
    json(conn, Enum.map(Evidence.list_for_record(type, id), &JSONHelpers.evidence/1))
  end

  def for_source(conn, %{"source_id" => source_id}) do
    json(conn, Enum.map(Evidence.list_for_source(source_id), &JSONHelpers.evidence/1))
  end

  def delete(conn, %{"id" => id}) do
    case Evidence.delete_reference(id) do
      {:ok, _reference} -> json(conn, %{deleted: true})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
