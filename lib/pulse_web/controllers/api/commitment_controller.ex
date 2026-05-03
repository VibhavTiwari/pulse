defmodule PulseWeb.Api.CommitmentController do
  use PulseWeb, :controller

  alias Pulse.Commitments
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(
      conn,
      Enum.map(Commitments.list_accepted(workspace_id, params), &JSONHelpers.commitment/1)
    )
  end

  def suggestions(conn, %{"workspace_id" => workspace_id} = params) do
    json(
      conn,
      Enum.map(Commitments.list_suggested(workspace_id, params), &JSONHelpers.commitment/1)
    )
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Commitments.create_manual_commitment(workspace_id, params) do
      {:ok, commitment} ->
        json(conn, JSONHelpers.commitment(commitment))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.commitment(Commitments.get_commitment!(workspace_id, id)))
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    commitment = Commitments.get_commitment!(workspace_id, id)

    case Commitments.update_commitment(commitment, params) do
      {:ok, commitment} ->
        json(conn, JSONHelpers.commitment(commitment))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def update_status(conn, %{"workspace_id" => workspace_id, "id" => id, "status" => status}) do
    commitment = Commitments.get_commitment!(workspace_id, id)

    case Commitments.update_status(commitment, status) do
      {:ok, commitment} ->
        json(conn, JSONHelpers.commitment(commitment))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def accept(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    commitment = Commitments.get_commitment!(workspace_id, id)

    case Commitments.accept_commitment(commitment) do
      {:ok, commitment} ->
        json(conn, JSONHelpers.commitment(commitment))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def reject(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    commitment = Commitments.get_commitment!(workspace_id, id)

    case Commitments.reject_commitment(commitment) do
      {:ok, commitment} ->
        json(conn, JSONHelpers.commitment(commitment))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def attach_evidence(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    commitment = Commitments.get_commitment!(workspace_id, id)

    case Commitments.attach_evidence(commitment, params) do
      {:ok, reference} ->
        json(conn, JSONHelpers.evidence(reference))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id, "source_id" => source_id}) do
    case Commitments.extract_from_source_id(workspace_id, source_id) do
      {:ok, commitments} ->
        json(conn, Enum.map(commitments, &JSONHelpers.commitment/1))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id}) do
    {:ok, commitments} = Commitments.extract_from_workspace(workspace_id)
    json(conn, Enum.map(commitments, &JSONHelpers.commitment/1))
  end
end
