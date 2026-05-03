defmodule Pulse.SourcesTest do
  use Pulse.DataCase

  alias Pulse.{Sources, Workspaces}

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Source Workspace", "root_path" => "C:/tmp/source"})

    %{workspace: workspace}
  end

  test "manual entry stores text and starts ready", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Notes",
        "source_type" => "note",
        "origin" => "manual_entry",
        "source_date" => "2026-05-03",
        "text_content" => "Private beta is the launch path."
      })

    assert source.processing_status == "ready"
    assert source.text_content == "Private beta is the launch path."
    assert [%{text: "Private beta is the launch path."}] = source.chunks
  end

  test "manual entry requires readable text", %{workspace: workspace} do
    {:error, changeset} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Empty",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => " "
      })

    assert "is required for manual entry sources" in errors_on(changeset).text_content
  end

  test "source type, origin, and ready text are validated", %{workspace: workspace} do
    {:error, changeset} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Invalid",
        "source_type" => "github_issue",
        "origin" => "slack",
        "text_content" => ""
      })

    assert "is invalid" in errors_on(changeset).source_type
    assert "is invalid" in errors_on(changeset).origin
    assert "is required when source is ready" in errors_on(changeset).text_content
  end

  test "uploaded text files become ready sources", %{workspace: workspace} do
    upload = upload_fixture("notes.txt", "The team committed to a Friday demo.")

    {:ok, source} =
      Sources.create_uploaded_source(workspace.id, upload, %{
        "title" => "Demo Notes",
        "source_type" => "document",
        "source_date" => "2026-05-03"
      })

    assert source.processing_status == "ready"
    assert source.origin == "manual_upload"
    assert source.text_content == "The team committed to a Friday demo."
  end

  test "unsupported uploads remain visible as failed sources", %{workspace: workspace} do
    upload = upload_fixture("deck.pdf", "%PDF binary-ish")

    {:ok, source} =
      Sources.create_uploaded_source(workspace.id, upload, %{
        "title" => "Deck",
        "source_type" => "document"
      })

    assert source.processing_status == "failed"
    assert source.text_content == nil
    assert source.error_message =~ "Unsupported upload format"
    assert [failed] = Sources.list_sources(workspace.id, %{"processing_status" => "failed"})
    assert failed.id == source.id
  end

  test "listing and retrieval are scoped to a workspace", %{workspace: workspace} do
    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other Workspace", "root_path" => "C:/tmp/other"})

    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Scoped",
        "source_type" => "transcript",
        "origin" => "manual_entry",
        "text_content" => "Only this workspace can see this."
      })

    assert [%{id: source_id}] =
             Sources.list_sources(workspace.id, %{"source_type" => "transcript"})

    assert source_id == source.id
    assert Sources.list_sources(other_workspace.id, %{"source_type" => "transcript"}) == []
    assert Sources.get_source_for_workspace(other_workspace.id, source.id) == nil
  end

  test "metadata and manual-entry text can be updated", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Old",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Old text."
      })

    {:ok, source} =
      Sources.update_source_metadata(source, %{
        "title" => "Updated",
        "source_type" => "project_update",
        "source_date" => "2026-05-03"
      })

    assert source.title == "Updated"
    assert source.source_type == "project_update"
    assert source.source_date == ~D[2026-05-03]

    {:ok, source} = Sources.update_source_text(source, "Updated text for Pulse.")
    assert source.processing_status == "ready"
    assert source.text_content == "Updated text for Pulse."
    assert [%{text: "Updated text for Pulse."}] = source.chunks
  end

  defp upload_fixture(filename, body) do
    path = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-#{filename}")
    File.write!(path, body)
    %Plug.Upload{path: path, filename: filename, content_type: "text/plain"}
  end
end
