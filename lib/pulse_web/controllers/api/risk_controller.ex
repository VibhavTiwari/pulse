defmodule PulseWeb.Api.RiskController do
  use PulseWeb, :controller

  alias Pulse.Risks
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Risks.list_accepted(workspace_id, params), &JSONHelpers.risk/1))
  end

  def suggestions(conn, %{"workspace_id" => workspace_id} = params) do
    json(conn, Enum.map(Risks.list_suggested(workspace_id, params), &JSONHelpers.risk/1))
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    case Risks.create_manual_risk(workspace_id, params) do
      {:ok, risk} ->
        json(conn, JSONHelpers.risk(risk))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(conn, JSONHelpers.risk(Risks.get_risk!(workspace_id, id)))
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    risk = Risks.get_risk!(workspace_id, id)

    case Risks.update_risk(risk, params) do
      {:ok, risk} ->
        json(conn, JSONHelpers.risk(risk))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def update_status(conn, %{"workspace_id" => workspace_id, "id" => id, "status" => status}) do
    risk = Risks.get_risk!(workspace_id, id)

    case Risks.update_status(risk, status) do
      {:ok, risk} ->
        json(conn, JSONHelpers.risk(risk))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def accept(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    risk = Risks.get_risk!(workspace_id, id)

    case Risks.accept_risk(risk) do
      {:ok, risk} -> json(conn, JSONHelpers.risk(risk))
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def reject(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    risk = Risks.get_risk!(workspace_id, id)

    case Risks.reject_risk(risk) do
      {:ok, risk} -> json(conn, JSONHelpers.risk(risk))
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def attach_evidence(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    risk = Risks.get_risk!(workspace_id, id)

    case Risks.attach_evidence(risk, params) do
      {:ok, reference} ->
        json(conn, JSONHelpers.evidence(reference))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id, "source_id" => source_id}) do
    case Risks.extract_from_source_id(workspace_id, source_id) do
      {:ok, risks} ->
        json(conn, Enum.map(risks, &JSONHelpers.risk/1))

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def extract(conn, %{"workspace_id" => workspace_id}) do
    {:ok, risks} = Risks.extract_from_workspace(workspace_id)
    json(conn, Enum.map(risks, &JSONHelpers.risk/1))
  end
end
