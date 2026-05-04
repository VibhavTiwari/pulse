defmodule PulseWeb.Api.DecisionController do
  use PulseWeb, :controller

  alias Pulse.Decisions
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Decisions.list_accepted(workspace_id, params), &JSONHelpers.decision/1))
  end

  def suggestions(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Decisions.list_suggested(workspace_id, params), &JSONHelpers.decision/1))
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Decisions.create_manual_decision(workspace_id, params) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.decision(Decisions.get_decision!(workspace_id, id)))
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.update_decision(decision, params) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def lifecycle(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.update_lifecycle(decision, params) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def reverse(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.reverse_decision(decision, params["reversal_reason"]) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def supersede(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "superseded_by_decision_id" => superseded_by_id
      }) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.supersede_decision(decision, superseded_by_id) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def accept(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.accept_decision(decision) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def reject(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.reject_decision(decision) do
      {:ok, decision} ->
        json(conn, JSONHelpers.decision(decision))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def attach_evidence(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    decision = Decisions.get_decision!(workspace_id, id)

    case Decisions.attach_evidence(decision, params) do
      {:ok, reference} ->
        json(conn, JSONHelpers.evidence(reference))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id, "source_id" => source_id}) do
    case Decisions.extract_from_source_id(workspace_id, source_id) do
      {:ok, decisions} ->
        json(conn, Enum.map(decisions, &JSONHelpers.decision/1))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id}) do
    {:ok, decisions} = Decisions.extract_from_workspace(workspace_id)
    json(conn, Enum.map(decisions, &JSONHelpers.decision/1))
  end
end
