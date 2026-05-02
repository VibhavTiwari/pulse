defmodule PulseWeb.Api.SourceController do
  use PulseWeb, :controller
  alias Pulse.Sources
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    sources = Sources.list_sources(workspace_id, params)
    json(conn, Enum.map(sources, &JSONHelpers.source/1))
  end

  def create_text(conn, %{"workspace_id" => workspace_id} = params) do
    case Sources.create_text_source(workspace_id, params) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def upload(conn, %{"workspace_id" => workspace_id, "file" => upload}) do
    case Sources.create_uploaded_source(workspace_id, upload) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    json(conn, JSONHelpers.source(Sources.get_source_with_chunks!(id)))
  end

  def delete(conn, %{"id" => id}) do
    source = Sources.get_source!(id)

    case Sources.delete_source(source) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end
end
