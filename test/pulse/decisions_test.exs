defmodule Pulse.DecisionsTest do
  use Pulse.DataCase

  alias Pulse.{Decisions, Evidence, Repo, Sources, Workspaces}
  alias Pulse.Sources.Source

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Decision Workspace", "root_path" => "C:/tmp/dl"})

    %{workspace: workspace}
  end

  test "manual decisions default to accepted manual project truth", %{workspace: workspace} do
    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Ship private beta",
        "context" => "The team will ship privately before public launch.",
        "decision_date" => "2026-05-03",
        "owner" => "Mira",
        "status" => "active"
      })

    assert decision.record_state == "accepted"
    assert decision.source_origin == "manual"
    assert decision.evidence == []
    assert [%{id: id}] = Decisions.list_accepted(workspace.id)
    assert id == decision.id
  end

  test "manual decisions require complete fields", %{workspace: workspace} do
    {:error, changeset} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "",
        "context" => "",
        "decision_date" => nil,
        "owner" => "",
        "status" => "paused"
      })

    errors = errors_on(changeset)
    assert "can't be blank" in errors.title
    assert "can't be blank" in errors.context
    assert "can't be blank" in errors.owner
    assert "can't be blank" in errors.decision_date
    assert "is invalid" in errors.status
  end

  test "decision lifecycle supports proposed accepted reversed and superseded states", %{
    workspace: workspace
  } do
    {:ok, proposed} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Consider private beta",
        "context" => "Team is considering a private beta path.",
        "decision_date" => "2026-05-03",
        "owner" => "Mira",
        "status" => "active",
        "decision_state" => "proposed",
        "rationale" => "Need a safer launch path",
        "tradeoffs" => "Less reach, more control"
      })

    assert proposed.decision_state == "proposed"
    assert proposed.rationale == "Need a safer launch path"
    assert [%{id: proposed_id}] = Decisions.list_accepted(workspace.id)
    assert proposed_id == proposed.id

    {:ok, accepted} = Decisions.accept_proposed_decision(proposed)
    assert accepted.decision_state == "accepted"

    {:ok, replacement} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Ship invite-only beta",
        "context" => "Invite-only beta replaces the broader private beta.",
        "decision_date" => "2026-05-04",
        "owner" => "Mira",
        "status" => "active"
      })

    {:ok, superseded} = Decisions.supersede_decision(accepted, replacement.id)
    assert superseded.decision_state == "superseded"
    assert superseded.superseded_by_decision_id == replacement.id
    assert superseded.superseded_by_decision.title == replacement.title
    refute Enum.any?(Decisions.list_accepted(workspace.id), &(&1.id == superseded.id))
    assert Enum.any?(Decisions.list_historical(workspace.id), &(&1.id == superseded.id))

    {:ok, reversed} = Decisions.reverse_decision(replacement, "Support model changed.")
    assert reversed.decision_state == "reversed"
    assert reversed.reversal_reason == "Support model changed."
    refute Enum.any?(Decisions.list_accepted(workspace.id), &(&1.id == reversed.id))
  end

  test "supersession rejects self and cross-workspace replacements", %{workspace: workspace} do
    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Scoped launch",
        "context" => "Keep launch scoped.",
        "decision_date" => "2026-05-03",
        "owner" => "Mira",
        "status" => "active"
      })

    assert {:error, changeset} = Decisions.supersede_decision(decision, decision.id)
    assert "cannot reference itself" in errors_on(changeset).superseded_by_decision_id

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other Decision", "root_path" => "C:/tmp/other-d"})

    {:ok, other_decision} =
      Decisions.create_manual_decision(other_workspace.id, %{
        "title" => "Other workspace replacement",
        "context" => "This belongs elsewhere.",
        "decision_date" => "2026-05-04",
        "owner" => "Rina",
        "status" => "active"
      })

    assert {:error, changeset} = Decisions.supersede_decision(decision, other_decision.id)

    assert "must be in the same workspace" in errors_on(changeset).superseded_by_decision_id
  end

  test "extracting from ready source creates suggested decisions with evidence", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Planning Notes",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "source_date" => "2026-05-03",
        "text_content" =>
          "The team decided to launch with a private beta. Owner is Mira. Open question: pricing remains unresolved."
      })

    {:ok, [suggestion]} = Decisions.extract_from_source_id(workspace.id, source.id)

    assert suggestion.record_state == "suggested"
    assert suggestion.source_origin == "extracted"
    assert suggestion.status == "active"
    assert suggestion.context =~ "decided to launch"
    assert [%{source_id: source_id, evidence_text: evidence_text}] = suggestion.evidence
    assert source_id == source.id
    assert evidence_text =~ "decided to launch"
    assert Decisions.list_accepted(workspace.id) == []
    assert [%{id: id}] = Decisions.list_suggested(workspace.id)
    assert id == suggestion.id
  end

  test "extraction skips pending, failed, and ambiguous sources", %{workspace: workspace} do
    {:ok, pending} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "The team decided to hide this pending decision."
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
        "text_content" => "The team discussed options and may choose a beta later."
      })

    assert {:error, :source_not_ready} = Decisions.extract_from_source(pending)
    assert {:ok, []} = Decisions.extract_from_workspace(workspace.id)
    assert {:ok, []} = Decisions.extract_from_source_id(workspace.id, ambiguous.id)
  end

  test "suggestions can be accepted or rejected and preserve evidence", %{workspace: workspace} do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Decision Source",
        "source_type" => "transcript",
        "origin" => "manual_entry",
        "text_content" => "The team decided to reduce launch scope. Owner is Mira."
      })

    {:ok, [suggestion]} = Decisions.extract_from_source_id(workspace.id, source.id)
    {:ok, accepted} = Decisions.accept_decision(suggestion)

    assert accepted.record_state == "accepted"
    assert [%{source_id: source_id}] = accepted.evidence
    assert source_id == source.id

    {:ok, [another]} = Decisions.extract_from_source_id(workspace.id, source.id)
    {:ok, rejected} = Decisions.reject_decision(another)
    assert rejected.record_state == "rejected"
    assert Enum.all?(Decisions.list_accepted(workspace.id), &(&1.id != rejected.id))
  end

  test "incomplete extracted suggestions cannot be accepted until completed", %{
    workspace: workspace
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Owner Missing",
        "source_type" => "document",
        "origin" => "manual_entry",
        "text_content" => "The team decided to delay public launch."
      })

    {:ok, [suggestion]} = Decisions.extract_from_source_id(workspace.id, source.id)
    assert suggestion.owner == "Unknown"
    assert {:error, :incomplete_decision} = Decisions.accept_decision(suggestion)

    {:ok, completed} = Decisions.update_decision(suggestion, %{"owner" => "Mira"})
    assert {:ok, accepted} = Decisions.accept_decision(completed)
    assert accepted.record_state == "accepted"
  end

  test "manual decisions can attach same-workspace evidence and reject cross-workspace evidence",
       %{
         workspace: workspace
       } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Manual Evidence",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Evidence for a manual decision."
      })

    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Manual with evidence",
        "context" => "Recorded by user with supporting source.",
        "decision_date" => "2026-05-03",
        "owner" => "Mira",
        "status" => "active",
        "evidence_source_id" => source.id,
        "evidence_text" => "Evidence for a manual decision."
      })

    assert [%{source_id: source_id}] = decision.evidence
    assert source_id == source.id

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other"})

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
               "target_entity_type" => "decision",
               "target_entity_id" => decision.id
             })
  end
end
