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

  def upload(conn, %{"workspace_id" => workspace_id, "file" => upload} = params) do
    case Sources.create_uploaded_source(workspace_id, upload, params) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{file: ["is required"]}})
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    json(
      conn,
      JSONHelpers.source(Sources.get_source_with_chunks_for_workspace!(workspace_id, id))
    )
  end

  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    source = Sources.get_source_for_workspace!(workspace_id, id)

    case Sources.update_source_metadata(source, params) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def update_text(conn, %{"workspace_id" => workspace_id, "id" => id, "text_content" => text}) do
    source = Sources.get_source_for_workspace!(workspace_id, id)

    case Sources.update_source_text(source, text) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end

  def update_text(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{text_content: ["is required"]}})
  end

  def delete(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    source = Sources.get_source_for_workspace!(workspace_id, id)

    case Sources.delete_source(source) do
      {:ok, source} ->
        json(conn, JSONHelpers.source(source))

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{errors: JSONHelpers.errors(changeset)})
    end
  end
end
