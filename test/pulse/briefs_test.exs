defmodule Pulse.BriefsTest do
  use Pulse.DataCase

  alias Pulse.Briefs
  alias Pulse.Briefs.Brief
  alias Pulse.{Commitments, Decisions, Evidence, Records, Repo, Sources, Workspaces}
  alias Pulse.Sources.Source

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Brief Workspace", "root_path" => "C:/tmp/db"})

    %{workspace: workspace, today: Date.utc_today()}
  end

  test "brief changeset requires daily type and structured P0 sections", %{
    workspace: workspace,
    today: today
  } do
    changeset =
      Brief.changeset(%Brief{}, %{
        "workspace_id" => workspace.id,
        "title" => "Daily Brief",
        "brief_date" => today,
        "brief_type" => "weekly",
        "summary" => "Summary",
        "sections" => %{"what_changed" => ["legacy item"]}
      })

    errors = errors_on(changeset)
    assert "is invalid" in errors.brief_type
    assert "must include what_changed and needs_attention" in errors.sections
    assert "what_changed[0] must be an object" in errors.sections
  end

  test "generates a saved daily brief from ready sources and accepted records only", %{
    workspace: workspace,
    today: today
  } do
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Standup",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "source_date" => today,
        "text_content" =>
          "The team decided to keep private beta scoped. Mira will resolve launch checklist blockers."
      })

    {:ok, pending_source} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending Notes",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "This pending source should not be used."
      })
      |> Repo.insert()

    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Keep private beta scoped",
        "context" => "The launch remains limited until support readiness is clear.",
        "decision_date" => today,
        "owner" => "Mira",
        "status" => "active",
        "evidence_source_id" => source.id,
        "evidence_text" => "The team decided to keep private beta scoped."
      })

    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Resolve launch checklist blockers",
        "description" => "Checklist work is holding the beta launch.",
        "owner" => "Mira",
        "due_date" => Date.add(today, -1),
        "due_date_known" => true,
        "status" => "open",
        "evidence_source_id" => source.id,
        "evidence_text" => "Mira will resolve launch checklist blockers."
      })

    {:ok, risk} =
      Records.create("risk", workspace.id, %{
        "title" => "Support readiness blocker",
        "description" => "Support coverage is blocking the beta expansion.",
        "severity" => "high",
        "owner" => "Rina",
        "status" => "open",
        "source_origin" => "manual"
      })

    {:ok, _risk_evidence} =
      Evidence.create_reference(workspace.id, %{
        "source_id" => source.id,
        "target_entity_type" => "risk",
        "target_entity_id" => risk.id,
        "evidence_text" => "support readiness is clear"
      })

    {:ok, _suggested} =
      Records.create("decision", workspace.id, %{
        "title" => "Suggested item must stay out",
        "context" => "Not accepted.",
        "decision_date" => today,
        "owner" => "Dev",
        "status" => "active",
        "record_state" => "suggested"
      })

    {:ok, brief} =
      Briefs.generate_daily_brief(workspace.id, %{
        "brief_date" => today,
        "window_days" => 7
      })

    assert brief.brief_type == "daily"
    assert brief.brief_date == today
    assert brief.summary =~ "Pulse found"

    what_changed = brief.sections["what_changed"]
    needs_attention = brief.sections["needs_attention"]
    titles = Enum.map(what_changed ++ needs_attention, & &1["title"])

    assert Enum.any?(titles, &String.contains?(&1, decision.title))
    assert Enum.any?(titles, &String.contains?(&1, commitment.title))
    assert Enum.any?(titles, &String.contains?(&1, risk.title))
    refute Enum.any?(titles, &String.contains?(&1, "Suggested item must stay out"))
    refute Enum.any?(what_changed, &String.contains?(&1["body"], pending_source.title))

    decision_item = Enum.find(what_changed, &(&1["linked_entity_id"] == decision.id))
    assert decision_item["evidence_state"] == "strong"
    assert [%{"source_id" => source_id}] = decision_item["evidence_refs"]
    assert source_id == source.id

    attention_commitment = Enum.find(needs_attention, &(&1["linked_entity_id"] == commitment.id))
    assert attention_commitment["title"] =~ "Overdue commitment"

    linked = Records.get!("brief", brief.id)
    assert Enum.any?(linked.decisions, &(&1.id == decision.id))
    assert Enum.any?(linked.commitments, &(&1.id == commitment.id))
    assert Enum.any?(linked.risks, &(&1.id == risk.id))
    assert [_brief_evidence | _] = Evidence.list_for_record("brief", brief.id)

    assert [%{"source_id" => source_id}] =
             Briefs.list_item_evidence(workspace.id, brief.id, decision_item["id"])

    assert source_id == source.id
  end

  test "generates an honest empty brief when no ready evidence or accepted records exist", %{
    workspace: workspace,
    today: today
  } do
    {:ok, _pending_source} =
      %Source{}
      |> Source.changeset(%{
        "workspace_id" => workspace.id,
        "title" => "Pending Only",
        "source_type" => "document",
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "text_content" => "Pending evidence should not be summarized."
      })
      |> Repo.insert()

    {:ok, brief} = Briefs.generate_daily_brief(workspace.id, %{"brief_date" => today})

    assert brief.summary =~ "No ready sources or accepted project records"

    assert [%{"item_type" => "other", "evidence_state" => "none"}] =
             brief.sections["what_changed"]

    assert [%{"item_type" => "other", "evidence_state" => "none"}] =
             brief.sections["needs_attention"]
  end
end
