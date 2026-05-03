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

  test "sources are automatically classified and manual classification is preserved", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Roadmap Plan",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Plan: launch milestones, timeline, owners, and sequencing."
      })

    assert source.classified_source_type == "plan"
    assert source.classification_confidence == "high"
    assert source.classification_method == "text_based"

    {:ok, source} =
      Sources.update_source_classification(source, %{"classified_source_type" => "document"})

    assert source.classified_source_type == "document"
    assert source.classification_confidence == "manual"
    assert source.classification_method == "manual"

    {:ok, source} =
      Sources.update_source_text(source, "Transcript: Mira said the project update is ready.")

    assert source.classified_source_type == "document"
    assert source.classification_method == "manual"
  end

  test "timeline orders by source date and uses created date fallback", %{workspace: workspace} do
    {:ok, older} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Older Update",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "source_date" => "2026-04-01",
        "text_content" => "Project update with enough source text to be useful."
      })

    {:ok, newer} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Newer Update",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "source_date" => "2026-05-01",
        "text_content" => "Project update with enough source text to be useful."
      })

    {:ok, fallback} =
      Sources.create_text_source(workspace.id, %{
        "title" => "No Source Date",
        "source_type" => "document",
        "origin" => "manual_entry",
        "text_content" => "Document with no source date but enough content for timeline fallback."
      })

    timeline = Sources.list_timeline(workspace.id)

    assert Enum.map(timeline, & &1.source.id) |> Enum.take(2) == [fallback.id, newer.id]

    assert Enum.find(timeline, &(&1.source.id == older.id)).timeline_date_basis == "source_date"
    assert Enum.find(timeline, &(&1.source.id == fallback.id)).timeline_date_basis == "created_at"
  end

  test "duplicate detection is workspace scoped and duplicate flags can be resolved", %{
    workspace: workspace
  } do
    text = "Launch update: Mira will keep the beta scoped until support readiness is clear."

    {:ok, original} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Update",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" => text
      })

    {:ok, duplicate} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Update Copy",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" => text
      })

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{
        "name" => "Duplicate Other",
        "root_path" => "C:/tmp/dup-other"
      })

    {:ok, _other_duplicate} =
      Sources.create_text_source(other_workspace.id, %{
        "title" => "Launch Update Copy",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" => text
      })

    assert [%{duplicate_type: "exact_duplicate", matched_source_id: matched_source_id} = flag] =
             Sources.list_duplicate_flags(workspace.id)

    assert matched_source_id == original.id
    assert flag.source_id == duplicate.id
    assert Sources.list_duplicate_flags(other_workspace.id) == []

    {:ok, confirmed} =
      Sources.resolve_duplicate_flag(workspace.id, flag.id, "confirmed_duplicate")

    assert confirmed.resolution_state == "confirmed_duplicate"

    assert Sources.list_duplicate_flags(workspace.id, %{"resolution_state" => "unresolved"}) == []
  end

  test "quality labels mark thin stale unclear pending and failed sources", %{
    workspace: workspace
  } do
    {:ok, thin} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Thin",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Short note."
      })

    assert thin.quality_label == "weak"
    assert "thin" in thin.quality_reasons

    {:ok, stale} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Stale Project Update",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "source_date" => "2025-01-01",
        "text_content" =>
          "This project update has enough useful content but the source date is old."
      })

    assert "stale" in stale.quality_reasons

    {:ok, unclear} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Unclear Notes",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "??? unclear [inaudible]"
      })

    assert unclear.quality_label == "poor"
    assert "unclear" in unclear.quality_reasons

    upload = upload_fixture("deck.pdf", "%PDF binary-ish")
    {:ok, failed} = Sources.create_uploaded_source(workspace.id, upload, %{"title" => "Failed"})

    assert failed.quality_label == "poor"
    assert "unclear" in failed.quality_reasons
  end

  defp upload_fixture(filename, body) do
    path = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-#{filename}")
    File.write!(path, body)
    %Plug.Upload{path: path, filename: filename, content_type: "text/plain"}
  end
end
