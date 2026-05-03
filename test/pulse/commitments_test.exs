defmodule Pulse.CommitmentsTest do
  use Pulse.DataCase

  alias Pulse.{Commitments, Evidence, Repo, Sources, Workspaces}
  alias Pulse.Sources.Source

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Commitment Workspace", "root_path" => "C:/tmp/cl"})

    %{workspace: workspace}
  end

  test "manual commitments default to accepted manual open records", %{workspace: workspace} do
    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Prepare launch checklist",
        "description" => "Checklist before private beta.",
        "owner" => "Mira",
        "due_date" => "2026-05-10",
        "due_date_known" => true
      })

    assert commitment.record_state == "accepted"
    assert commitment.source_origin == "manual"
    assert commitment.status == "open"
    assert commitment.due_date == ~D[2026-05-10]
    assert commitment.due_date_known == true
    assert [%{id: id}] = Commitments.list_accepted(workspace.id)
    assert id == commitment.id
  end

  test "manual commitments require title owner status and due date consistency", %{
    workspace: workspace
  } do
    {:error, changeset} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "",
        "owner" => "",
        "due_date_known" => true,
        "status" => "paused"
      })

    errors = errors_on(changeset)
    assert "can't be blank" in errors.title
    assert "can't be blank" in errors.owner
    assert "is required when due_date_known is true" in errors.due_date
    assert "is invalid" in errors.status
  end

  test "manual commitments can explicitly mark due date unknown", %{workspace: workspace} do
    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Investigate vendor option",
        "owner" => "Dev",
        "due_date_known" => false,
        "status" => "blocked"
      })

    assert commitment.due_date == nil
    assert commitment.due_date_known == false
    assert commitment.status == "blocked"
  end

  test "extracting from ready source creates suggested commitments with evidence and due date", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Action Notes",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" =>
          "Action item: Mira will prepare the launch checklist by 2026-05-10. Open question: pricing remains unresolved."
      })

    {:ok, [suggestion]} = Commitments.extract_from_source_id(workspace.id, source.id)

    assert suggestion.record_state == "suggested"
    assert suggestion.source_origin == "extracted"
    assert suggestion.status == "open"
    assert suggestion.owner == "Mira"
    assert suggestion.due_date == ~D[2026-05-10]
    assert suggestion.due_date_known == true
    assert [%{source_id: source_id, evidence_text: evidence_text}] = suggestion.evidence
    assert source_id == source.id
    assert evidence_text =~ "prepare the launch checklist"
    assert Commitments.list_accepted(workspace.id) == []
    assert [%{id: id}] = Commitments.list_suggested(workspace.id)
    assert id == suggestion.id
  end

  test "extraction marks missing due date unknown and skips pending failed ambiguous sources", %{
    workspace: workspace
  } do
    {:ok, pending} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "Action item: Mira will hide this pending task."
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

    {:ok, ambiguous} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Discussion",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "The team discussed possible follow-ups and may assign work later."
      })

    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "No Due Date",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" => "Next step: Mira will draft onboarding notes."
      })

    assert {:error, :source_not_ready} = Commitments.extract_from_source(pending)
    assert {:ok, []} = Commitments.extract_from_source_id(workspace.id, ambiguous.id)
    {:ok, [suggestion]} = Commitments.extract_from_source_id(workspace.id, source.id)
    assert suggestion.due_date == nil
    assert suggestion.due_date_known == false
  end

  test "suggestions can be accepted or rejected and preserve evidence", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Commitment Source",
        "source_type" => "transcript",
        "origin" => "manual_entry",
        "text_content" => "Action item: Mira will finalize the launch FAQ by 2026-05-10."
      })

    {:ok, [suggestion]} = Commitments.extract_from_source_id(workspace.id, source.id)
    {:ok, accepted} = Commitments.accept_commitment(suggestion)

    assert accepted.record_state == "accepted"
    assert [%{source_id: source_id}] = accepted.evidence
    assert source_id == source.id

    {:ok, [another]} = Commitments.extract_from_source_id(workspace.id, source.id)
    {:ok, rejected} = Commitments.reject_commitment(another)
    assert rejected.record_state == "rejected"
    assert Enum.all?(Commitments.list_accepted(workspace.id), &(&1.id != rejected.id))
  end

  test "incomplete owner suggestions cannot be accepted until completed", %{workspace: workspace} do
    {:ok, commitment} =
      %Pulse.Commitments.Commitment{}
      |> Pulse.Commitments.Commitment.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Complete unknown owner task",
        "owner" => "Unknown",
        "due_date_known" => false,
        "status" => "open",
        "record_state" => "suggested",
        "source_origin" => "manual"
      })
      |> Repo.insert()

    assert {:error, :incomplete_commitment} = Commitments.accept_commitment(commitment)

    {:ok, completed} = Commitments.update_commitment(commitment, %{"owner" => "Mira"})
    assert {:ok, accepted} = Commitments.accept_commitment(completed)
    assert accepted.record_state == "accepted"
  end

  test "status updates and status filters only apply to accepted commitments", %{
    workspace: workspace
  } do
    {:ok, open} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Open task",
        "owner" => "Mira",
        "due_date_known" => false
      })

    {:ok, done} = Commitments.update_status(open, "done")
    assert done.status == "done"
    assert [%{id: id}] = Commitments.list_accepted(workspace.id, %{"status" => "done"})
    assert id == open.id
    assert Commitments.list_accepted(workspace.id, %{"status" => "open"}) == []
  end

  test "manual commitments can attach evidence and reject cross-workspace evidence", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Manual Commitment Evidence",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Evidence for a manual commitment."
      })

    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Manual with evidence",
        "owner" => "Mira",
        "due_date_known" => false,
        "evidence_source_id" => source.id,
        "evidence_text" => "Evidence for a manual commitment."
      })

    assert [%{source_id: source_id}] = commitment.evidence
    assert source_id == source.id

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other-cl"})

    {:ok, other_source} =
      Sources.create_text_source(other_workspace.id, %{
        "title" => "Other Source",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Cross workspace evidence."
      })

    assert {:error, :source_workspace_mismatch} =
             Evidence.create_reference(workspace.id, %{
               "source_id" => other_source.id,
               "target_entity_type" => "commitment",
               "target_entity_id" => commitment.id
             })
  end
end
