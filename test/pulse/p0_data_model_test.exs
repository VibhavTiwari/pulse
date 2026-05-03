defmodule Pulse.P0DataModelTest do
  use Pulse.DataCase

  alias Pulse.{Evidence, Records, Sources, Workspaces}

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Test Workspace", "root_path" => "C:/tmp/pulse"})

    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Notes",
        "source_type" => "document",
        "origin" => "manual_entry",
        "text_content" =>
          "The launch should prioritize a private beta. Every answer must include citations."
      })

    %{workspace: workspace, source: source}
  end

  test "suggested records are excluded from project truth until accepted", %{
    workspace: workspace,
    source: source
  } do
    {:ok, decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Private beta",
        "context" => "Launch privately first.",
        "decision_date" => "2026-05-02",
        "owner" => "Rina",
        "status" => "active",
        "record_state" => "suggested"
      })

    assert Records.list("decision", workspace.id) == []

    {:ok, _evidence} =
      Evidence.create_reference(workspace.id, %{
        "source_id" => source.id,
        "target_entity_type" => "decision",
        "target_entity_id" => decision.id,
        "evidence_text" => "The launch should prioritize a private beta."
      })

    {:ok, accepted} = Records.transition_state("decision", decision, "accepted")
    assert accepted.record_state == "accepted"
    assert [%{id: id}] = Records.list("decision", workspace.id)
    assert id == decision.id
    assert [%{source_id: source_id}] = Evidence.list_for_record("decision", decision.id)
    assert source_id == source.id
  end

  test "commitment due date consistency is enforced", %{workspace: workspace} do
    {:error, changeset} =
      Records.create("commitment", workspace.id, %{
        "title" => "Ship follow-up",
        "owner" => "Dev",
        "due_date_known" => true,
        "status" => "open"
      })

    assert %{due_date: ["is required when due_date_known is true"]} = errors_on(changeset)
  end

  test "cross-workspace evidence references are rejected", %{source: source} do
    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other", "root_path" => "C:/tmp/other"})

    {:ok, risk} =
      Records.create("risk", other_workspace.id, %{
        "title" => "Mismatched evidence",
        "description" => "Evidence should not cross workspaces.",
        "severity" => "high",
        "owner" => "Dev",
        "status" => "open"
      })

    assert {:error, :source_workspace_mismatch} =
             Evidence.create_reference(other_workspace.id, %{
               "source_id" => source.id,
               "target_entity_type" => "risk",
               "target_entity_id" => risk.id
             })
  end

  test "meetings and briefs link accepted project records", %{workspace: workspace} do
    {:ok, decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Citations required",
        "context" => "Answers need citations.",
        "decision_date" => "2026-05-02",
        "owner" => "Dev",
        "status" => "active"
      })

    {:ok, meeting} =
      Records.create("meeting", workspace.id, %{
        "title" => "Planning",
        "meeting_date" => "2026-05-03"
      })

    {:ok, linked_meeting} = Records.link("meeting", meeting.id, "decision", decision.id)
    assert [%{id: id}] = linked_meeting.decisions
    assert id == decision.id

    {:ok, brief} =
      Records.create("brief", workspace.id, %{
        "title" => "Daily Brief",
        "brief_date" => "2026-05-02",
        "brief_type" => "daily",
        "summary" => "What changed and what needs attention.",
        "sections" => %{
          "what_changed" => [
            %{
              "id" => "decision-accepted",
              "section" => "what_changed",
              "title" => "Decision accepted",
              "body" => "Answers need citations.",
              "item_type" => "decision",
              "linked_entity_type" => "decision",
              "linked_entity_id" => decision.id,
              "evidence_state" => "none",
              "evidence_refs" => []
            }
          ],
          "needs_attention" => []
        }
      })

    {:ok, linked_brief} = Records.link("brief", brief.id, "meeting", meeting.id)
    assert [%{id: id}] = linked_brief.meetings
    assert id == meeting.id
  end
end
