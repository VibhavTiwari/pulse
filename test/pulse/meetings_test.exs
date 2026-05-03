defmodule Pulse.MeetingsTest do
  use Pulse.DataCase

  alias Pulse.{Commitments, Decisions, Evidence, Meetings, Records, Sources, Workspaces}

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Meeting Workspace", "root_path" => "C:/tmp/mp"})

    %{workspace: workspace, today: Date.utc_today()}
  end

  test "meetings can be created updated listed and scoped to a workspace", %{
    workspace: workspace,
    today: today
  } do
    {:ok, meeting} =
      Meetings.create_meeting(workspace.id, %{
        "title" => "Launch readiness review",
        "meeting_date" => today,
        "description" => "Review beta launch readiness.",
        "attendees" => ["Mira", "Rina"]
      })

    assert meeting.workspace_id == workspace.id
    assert meeting.title == "Launch readiness review"
    assert meeting.attendees == ["Mira", "Rina"]

    {:ok, updated} =
      Meetings.update_meeting(meeting, %{
        "title" => "Beta readiness review",
        "description" => "Updated context"
      })

    assert updated.title == "Beta readiness review"
    assert updated.description == "Updated context"
    assert [%{id: id}] = Meetings.list_meetings(workspace.id)
    assert id == meeting.id

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other-mp"})

    assert Meetings.list_meetings(other_workspace.id) == []
  end

  test "meeting creation requires title and date", %{workspace: workspace} do
    {:error, changeset} =
      Meetings.create_meeting(workspace.id, %{
        "title" => "",
        "description" => "Missing date too."
      })

    errors = errors_on(changeset)
    assert "can't be blank" in errors.title
    assert "can't be blank" in errors.meeting_date
  end

  test "prep includes relevant accepted decisions and open commitments with evidence", %{
    workspace: workspace,
    today: today
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Context",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" =>
          "The team decided to keep private beta scoped. Mira will finish launch checklist."
      })

    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Private beta scope",
        "context" => "Keep private beta scoped until readiness is clear.",
        "decision_date" => today,
        "owner" => "Mira",
        "status" => "active",
        "evidence_source_id" => source.id,
        "evidence_text" => "The team decided to keep private beta scoped."
      })

    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Finish launch checklist",
        "description" => "Checklist gates the private beta launch.",
        "owner" => "Mira",
        "due_date_known" => false,
        "status" => "open",
        "evidence_source_id" => source.id,
        "evidence_text" => "Mira will finish launch checklist."
      })

    {:ok, done} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Done launch cleanup",
        "description" => "Should not appear as open work.",
        "owner" => "Mira",
        "due_date_known" => false,
        "status" => "done"
      })

    {:ok, _suggested_decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Private beta suggested",
        "context" => "Not accepted.",
        "decision_date" => today,
        "owner" => "Dev",
        "status" => "active",
        "record_state" => "suggested"
      })

    {:ok, _rejected_commitment} =
      Records.create("commitment", workspace.id, %{
        "title" => "Rejected launch follow-up",
        "owner" => "Dev",
        "due_date_known" => false,
        "status" => "open",
        "record_state" => "rejected"
      })

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other-mp"})

    {:ok, _other_decision} =
      Decisions.create_manual_decision(other_workspace.id, %{
        "title" => "Private beta other workspace",
        "context" => "Should not leak.",
        "decision_date" => today,
        "owner" => "Other",
        "status" => "active"
      })

    {:ok, meeting} =
      Meetings.create_meeting(workspace.id, %{
        "title" => "Private beta launch review",
        "meeting_date" => today,
        "description" => "Review launch checklist and private beta scope."
      })

    prep = Meetings.get_prep(workspace.id, meeting.id)

    assert [%{id: id, evidence: [_]}] = prep.relevant_decisions
    assert id == decision.id
    assert [%{id: id, evidence: [_]}] = prep.open_commitments
    assert id == commitment.id
    refute Enum.any?(prep.open_commitments, &(&1.id == done.id))
    assert Enum.any?(prep.agenda_items, &(&1["linked_entity_id"] == decision.id))
    assert Enum.any?(prep.agenda_items, &(&1["linked_entity_id"] == commitment.id))

    refreshed = Meetings.refresh_prep(workspace.id, meeting.id)
    assert Enum.any?(refreshed.meeting.decisions, &(&1.id == decision.id))
    assert Enum.any?(refreshed.meeting.commitments, &(&1.id == commitment.id))
    assert [%{source_id: source_id}] = Evidence.list_for_record("decision", decision.id)
    assert source_id == source.id
  end

  test "explicit links require accepted decisions and non-done accepted commitments", %{
    workspace: workspace,
    today: today
  } do
    {:ok, meeting} =
      Meetings.create_meeting(workspace.id, %{
        "title" => "Operations sync",
        "meeting_date" => today
      })

    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Adopt support rotation",
        "context" => "Use an on-call rotation.",
        "decision_date" => today,
        "owner" => "Rina",
        "status" => "active"
      })

    {:ok, suggested_decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Suggested only",
        "context" => "Not accepted.",
        "decision_date" => today,
        "owner" => "Dev",
        "status" => "active",
        "record_state" => "suggested"
      })

    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Prepare support checklist",
        "owner" => "Rina",
        "due_date_known" => false,
        "status" => "open"
      })

    {:ok, done_commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Completed prep",
        "owner" => "Rina",
        "due_date_known" => false,
        "status" => "done"
      })

    assert {:ok, linked} = Meetings.link_decision(meeting, decision.id)
    assert Enum.any?(linked.decisions, &(&1.id == decision.id))

    assert {:error, :decision_not_accepted} =
             Meetings.link_decision(meeting, suggested_decision.id)

    assert {:ok, linked} = Meetings.link_commitment(meeting, commitment.id)
    assert Enum.any?(linked.commitments, &(&1.id == commitment.id))
    assert {:error, :commitment_done} = Meetings.link_commitment(meeting, done_commitment.id)

    assert {:ok, unlinked} = Meetings.unlink_decision(meeting, decision.id)
    refute Enum.any?(unlinked.decisions, &(&1.id == decision.id))
    assert {:ok, unlinked} = Meetings.unlink_commitment(meeting, commitment.id)
    refute Enum.any?(unlinked.commitments, &(&1.id == commitment.id))
  end

  test "insufficient context produces an explicit agenda state", %{
    workspace: workspace,
    today: today
  } do
    {:ok, meeting} =
      Meetings.create_meeting(workspace.id, %{
        "title" => "Weekly sync",
        "meeting_date" => today
      })

    prep = Meetings.get_prep(workspace.id, meeting.id)
    assert prep.relevant_decisions == []
    assert prep.open_commitments == []

    assert [%{"title" => "Not enough project context", "evidence_state" => "none"}] =
             prep.agenda_items
  end
end
