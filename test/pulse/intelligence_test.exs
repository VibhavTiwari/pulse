defmodule Pulse.IntelligenceTest do
  use Pulse.DataCase

  alias Pulse.{Intelligence, Repo, Sources, Workspaces}
  alias Pulse.Sources.Source

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Intel Workspace", "root_path" => "C:/tmp/intel"})

    %{workspace: workspace}
  end

  test "ready sources are indexed as searchable passages", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Notes",
        "source_type" => "document",
        "origin" => "manual_entry",
        "text_content" => "The launch plan is a focused private beta before public announcement."
      })

    assert [%{source_id: source_id, passage_text: text, source_title: "Launch Notes"}] =
             Intelligence.search(workspace.id, "private beta launch")

    assert source_id == source.id
    assert text =~ "private beta"
  end

  test "pending and failed sources are not indexed for search", %{workspace: workspace} do
    {:ok, _pending} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "This pending source mentions a secret launch."
      })
      |> Repo.insert()

    {:ok, _failed} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Failed",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "failed"
      })
      |> Repo.insert()

    assert Intelligence.search(workspace.id, "secret launch") == []
  end

  test "reindexing replaces old passages when source text changes", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Plan",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "The old plan mentions alpha."
      })

    assert [_] = Intelligence.search(workspace.id, "alpha")

    {:ok, _source} = Sources.update_source_text(source, "The updated plan mentions beta.")

    assert Intelligence.search(workspace.id, "alpha") == []
    assert [_] = Intelligence.search(workspace.id, "beta")
  end

  test "search is workspace-scoped", %{workspace: workspace} do
    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other Intel", "root_path" => "C:/tmp/other"})

    {:ok, _source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Scoped",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Scoped evidence mentions capacity risk."
      })

    assert [_] = Intelligence.search(workspace.id, "capacity risk")
    assert Intelligence.search(other_workspace.id, "capacity risk") == []
  end
end
