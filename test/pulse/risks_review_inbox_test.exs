defmodule Pulse.RisksReviewInboxTest do
  use Pulse.DataCase

  alias Pulse.{Commitments, Decisions, Evidence, Repo, ReviewInbox, Risks, Sources, Workspaces}
  alias Pulse.Sources.Source

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Risk Workspace", "root_path" => "C:/tmp/rr"})

    %{workspace: workspace}
  end

  test "manual risks default to accepted manual open records", %{workspace: workspace} do
    {:ok, risk} =
      Risks.create_manual_risk(workspace.id, %{
        "title" => "Launch readiness blocker",
        "description" => "Support coverage is not ready.",
        "severity" => "high",
        "owner" => "Mira"
      })

    assert risk.record_state == "accepted"
    assert risk.source_origin == "manual"
    assert risk.status == "open"
    assert [%{id: id}] = Risks.list_accepted(workspace.id)
    assert id == risk.id
  end

  test "manual risks require complete fields and valid severity status", %{workspace: workspace} do
    {:error, changeset} =
      Risks.create_manual_risk(workspace.id, %{
        "title" => "",
        "description" => "",
        "severity" => "urgent",
        "owner" => "",
        "status" => "blocked"
      })

    errors = errors_on(changeset)
    assert "can't be blank" in errors.title
    assert "can't be blank" in errors.description
    assert "can't be blank" in errors.owner
    assert "is invalid" in errors.severity
    assert "is invalid" in errors.status
  end

  test "extracting from ready source creates suggested risks with evidence", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Risk Notes",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" =>
          "Blocker: support readiness is blocking beta launch; owner is Mira; mitigation is add support coverage."
      })

    {:ok, [suggestion]} = Risks.extract_from_source_id(workspace.id, source.id)

    assert suggestion.record_state == "suggested"
    assert suggestion.source_origin == "extracted"
    assert suggestion.status == "open"
    assert suggestion.severity in ["high", "critical"]
    assert suggestion.owner == "Mira"
    assert suggestion.mitigation =~ "add support coverage"
    assert [%{source_id: source_id, evidence_text: evidence_text}] = suggestion.evidence
    assert source_id == source.id
    assert evidence_text =~ "support readiness"
    assert Risks.list_accepted(workspace.id) == []
    assert [%{id: id}] = Risks.list_suggested(workspace.id)
    assert id == suggestion.id
  end

  test "risk extraction skips pending failed and vague sources", %{workspace: workspace} do
    {:ok, pending} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "Blocker: pending text should not create a risk."
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

    {:ok, vague} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Brainstorm",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "The team may have a possible concern during future brainstorming."
      })

    assert {:error, :source_not_ready} = Risks.extract_from_source(pending)
    assert {:ok, []} = Risks.extract_from_source_id(workspace.id, vague.id)
    {:ok, suggestions} = Risks.extract_from_workspace(workspace.id)
    assert suggestions == []
  end

  test "extracted risks need complete owner and evidence before acceptance", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Unknown Owner Risk",
        "source_type" => "transcript",
        "origin" => "manual_entry",
        "text_content" => "Risk: vendor dependency is unresolved and blocking launch."
      })

    {:ok, [suggestion]} = Risks.extract_from_source_id(workspace.id, source.id)
    assert suggestion.owner == "Unknown"
    assert {:error, :incomplete_risk} = Risks.accept_risk(suggestion)

    {:ok, completed} =
      Risks.update_risk(suggestion, %{"owner" => "Rina", "severity" => "critical"})

    {:ok, accepted} = Risks.accept_risk(completed)
    assert accepted.record_state == "accepted"
    assert accepted.severity == "critical"
    assert [%{source_id: source_id}] = accepted.evidence
    assert source_id == source.id
  end

  test "review inbox lists and transitions suggestions across record types", %{
    workspace: workspace
  } do
    {:ok, decision_source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Decision Review Source",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" => "The team decided to keep beta scoped. Owner is Mira."
      })

    {:ok, commitment_source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Commitment Review Source",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" => "Action item: Mira will finish launch checklist."
      })

    {:ok, risk_source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Risk Review Source",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" => "Blocker: support coverage is blocking beta expansion; owner is Rina."
      })

    {:ok, [decision]} = Decisions.extract_from_source_id(workspace.id, decision_source.id)
    {:ok, [commitment]} = Commitments.extract_from_source_id(workspace.id, commitment_source.id)
    {:ok, [risk]} = Risks.extract_from_source_id(workspace.id, risk_source.id)

    types = workspace.id |> ReviewInbox.list_suggestions() |> Enum.map(& &1.type) |> Enum.sort()
    assert types == ["commitment", "decision", "risk"]

    assert [%{type: "risk", record: %{id: risk_id}}] =
             ReviewInbox.list_suggestions(workspace.id, %{"type" => "risk"})

    assert risk_id == risk.id

    {:ok, updated_risk} =
      ReviewInbox.update_suggestion(workspace.id, "risk", risk.id, %{
        "owner" => "Mira",
        "severity" => "critical"
      })

    assert updated_risk.owner == "Mira"
    assert updated_risk.severity == "critical"

    {:ok, accepted_decision} =
      ReviewInbox.accept_suggestion(workspace.id, "decision", decision.id)

    assert accepted_decision.record_state == "accepted"

    {:ok, rejected_commitment} =
      ReviewInbox.reject_suggestion(workspace.id, "commitment", commitment.id)

    assert rejected_commitment.record_state == "rejected"

    {:ok, accepted_risk} = ReviewInbox.accept_suggestion(workspace.id, "risk", risk.id)
    assert accepted_risk.record_state == "accepted"

    assert Enum.all?(
             ReviewInbox.list_suggestions(workspace.id),
             &(&1.id not in [decision.id, commitment.id, risk.id])
           )
  end

  test "risk evidence rejects cross-workspace sources", %{workspace: workspace} do
    {:ok, risk} =
      Risks.create_manual_risk(workspace.id, %{
        "title" => "Manual risk",
        "description" => "Needs evidence validation.",
        "severity" => "medium",
        "owner" => "Mira"
      })

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other-rr"})

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
               "target_entity_type" => "risk",
               "target_entity_id" => risk.id
             })
  end
end
