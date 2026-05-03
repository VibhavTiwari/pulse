defmodule PulseWeb.ApiControllerTest do
  use PulseWeb.ConnCase

  test "workspace source ask flow works through JSON APIs", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "API Workspace", root_path: "C:/tmp/api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Launch Notes",
        source_type: "document",
        origin: "manual_entry",
        text_content:
          "The launch should prioritize a focused private beta before public announcement."
      })

    source = json_response(conn, 200)
    assert source["processing_status"] == "ready"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/ask", %{
        question: "What is the launch plan?"
      })

    answer = json_response(conn, 200)
    assert answer["answer_id"]
    assert answer["thread_id"]
    assert answer["evidence_state"] in ["strong", "weak", "mixed"]
    assert [_citation] = answer["citations"]

    conn =
      post(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/ask_threads/#{answer["thread_id"]}/messages",
        %{
          question: "What kind of beta?"
        }
      )

    follow_up = json_response(conn, 200)
    assert follow_up["thread_id"] == answer["thread_id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/ask_threads/#{answer["thread_id"]}")
    thread = json_response(conn, 200)
    assert length(thread["messages"]) == 4
  end

  test "ask API returns explicit no-evidence state without citations", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "No Evidence API", root_path: "C:/tmp/none"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/ask", %{
        question: "What is the pricing model?"
      })

    answer = json_response(conn, 200)
    assert answer["evidence_state"] == "none"
    assert answer["citations"] == []
    assert answer["answer"] =~ "do not have enough evidence"
  end

  test "source library APIs create, filter, view, and update sources", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "Source API", root_path: "C:/tmp/api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Meeting Transcript",
        source_type: "transcript",
        origin: "manual_entry",
        source_date: "2026-05-03",
        text_content: "The rollout risk is unresolved until owners confirm capacity."
      })

    source = json_response(conn, 200)
    assert source["processing_status"] == "ready"

    conn =
      get(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/sources?processing_status=ready&source_type=transcript"
      )

    assert [%{"id" => source_id}] = json_response(conn, 200)
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}")
    viewed = json_response(conn, 200)
    assert viewed["text_content"] =~ "rollout risk"
    assert [%{"text" => chunk_text}] = viewed["chunks"]
    assert chunk_text =~ "owners confirm capacity"

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}", %{
        title: "Updated Transcript",
        source_type: "meeting_note",
        source_date: "2026-05-04"
      })

    updated = json_response(conn, 200)
    assert updated["title"] == "Updated Transcript"
    assert updated["source_type"] == "meeting_note"
    assert updated["source_date"] == "2026-05-04"

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}/text", %{
        text_content: "The rollout risk now has a named mitigation owner."
      })

    updated_text = json_response(conn, 200)
    assert updated_text["processing_status"] == "ready"
    assert updated_text["text_content"] =~ "named mitigation owner"
  end

  test "P1 source library APIs expose classification timeline duplicate and quality signals", %{
    conn: conn
  } do
    conn = post(conn, ~p"/api/workspaces", %{name: "P1 Source API", root_path: "C:/tmp/p1-src"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Launch Roadmap Plan",
        source_type: "note",
        origin: "manual_entry",
        source_date: "2026-05-01",
        text_content:
          "Plan: launch milestones, owner sequence, beta timeline, support readiness, and rollout strategy."
      })

    plan = json_response(conn, 200)
    assert plan["classified_source_type"] == "plan"
    assert plan["classification_confidence"] == "high"
    assert plan["quality_label"] in ["usable", "strong"]

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{plan["id"]}/classification", %{
        classified_source_type: "document"
      })

    manual = json_response(conn, 200)
    assert manual["classified_source_type"] == "document"
    assert manual["classification_confidence"] == "manual"
    assert manual["classification_method"] == "manual"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Launch Roadmap Plan Copy",
        source_type: "note",
        origin: "manual_entry",
        text_content:
          "Plan: launch milestones, owner sequence, beta timeline, support readiness, and rollout strategy."
      })

    copy = json_response(conn, 200)
    assert copy["duplicate_count"] == 1

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/timeline")
    timeline = json_response(conn, 200)

    assert [%{"timeline_date_basis" => "created_at"}, %{"timeline_date_basis" => "source_date"}] =
             timeline

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/duplicates")

    assert [%{"duplicate_type" => "exact_duplicate", "resolution_state" => "unresolved"} = flag] =
             json_response(conn, 200)

    conn =
      get(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/source_duplicate_flags/#{flag["id"]}"
      )

    detail = json_response(conn, 200)
    assert detail["id"] == flag["id"]
    assert detail["matched_source_id"] == plan["id"]
    assert detail["matched_source_title"] == "Launch Roadmap Plan"
    assert detail["reason"] =~ "Readable text"

    conn =
      post(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/source_duplicate_flags/#{flag["id"]}/dismiss"
      )

    dismissed = json_response(conn, 200)
    assert dismissed["resolution_state"] == "dismissed"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{copy["id"]}/reassess_quality")

    reassessed = json_response(conn, 200)
    assert reassessed["quality_label"] in ["usable", "strong"]
  end

  test "decision log APIs support manual creation, extraction, and approval", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "Decision API", root_path: "C:/tmp/dl-api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions", %{
        title: "Manual decision",
        context: "User recorded this directly.",
        decision_date: "2026-05-03",
        owner: "Mira",
        status: "active"
      })

    manual = json_response(conn, 200)
    assert manual["record_state"] == "accepted"
    assert manual["source_origin"] == "manual"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Decision Transcript",
        source_type: "transcript",
        origin: "manual_entry",
        source_date: "2026-05-03",
        text_content: "The team decided to launch with private beta. Owner is Mira."
      })

    source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions/extract", %{
        source_id: source["id"]
      })

    [suggestion] = json_response(conn, 200)
    assert suggestion["record_state"] == "suggested"
    assert suggestion["source_origin"] == "extracted"
    assert [%{"source_id" => source_id}] = suggestion["evidence"]
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/decision_suggestions")
    assert [%{"id" => suggestion_id}] = json_response(conn, 200)
    assert suggestion_id == suggestion["id"]

    conn = post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions/#{suggestion["id"]}/accept")
    accepted = json_response(conn, 200)
    assert accepted["record_state"] == "accepted"
    assert [%{"source_id" => source_id}] = accepted["evidence"]
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions")
    accepted_decisions = json_response(conn, 200)
    assert Enum.any?(accepted_decisions, &(&1["id"] == accepted["id"]))
  end

  test "commitment ledger APIs support manual creation, extraction, status, and approval", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/workspaces", %{name: "Commitment API", root_path: "C:/tmp/cl-api"})

    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments", %{
        title: "Manual commitment",
        description: "User recorded this directly.",
        owner: "Mira",
        due_date: "2026-05-10",
        due_date_known: true,
        status: "open"
      })

    manual = json_response(conn, 200)
    assert manual["record_state"] == "accepted"
    assert manual["source_origin"] == "manual"
    assert manual["status"] == "open"

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments/#{manual["id"]}/status", %{
        status: "blocked"
      })

    blocked = json_response(conn, 200)
    assert blocked["status"] == "blocked"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Commitment Transcript",
        source_type: "transcript",
        origin: "manual_entry",
        text_content: "Action item: Mira will finalize the launch FAQ by 2026-05-10."
      })

    source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments/extract", %{
        source_id: source["id"]
      })

    [suggestion] = json_response(conn, 200)
    assert suggestion["record_state"] == "suggested"
    assert suggestion["source_origin"] == "extracted"
    assert suggestion["due_date_known"] == true
    assert [%{"source_id" => source_id}] = suggestion["evidence"]
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/commitment_suggestions")
    assert [%{"id" => suggestion_id}] = json_response(conn, 200)
    assert suggestion_id == suggestion["id"]

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments/#{suggestion["id"]}/accept")

    accepted = json_response(conn, 200)
    assert accepted["record_state"] == "accepted"
    assert [%{"source_id" => source_id}] = accepted["evidence"]
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments?status=open")
    accepted_commitments = json_response(conn, 200)
    assert Enum.any?(accepted_commitments, &(&1["id"] == accepted["id"]))
    refute Enum.any?(accepted_commitments, &(&1["id"] == manual["id"]))
  end

  test "daily brief APIs generate, save, retrieve, and expose item evidence", %{conn: conn} do
    today = Date.utc_today()
    conn = post(conn, ~p"/api/workspaces", %{name: "Brief API", root_path: "C:/tmp/db-api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Brief Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        source_date: Date.to_iso8601(today),
        text_content:
          "The team decided to keep private beta scoped. Mira will finish launch checklist by tomorrow."
      })

    source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions", %{
        title: "Keep beta scoped",
        context: "Limit beta until launch readiness is clear.",
        decision_date: Date.to_iso8601(today),
        owner: "Mira",
        status: "active",
        evidence_source_id: source["id"],
        evidence_text: "The team decided to keep private beta scoped."
      })

    decision = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments", %{
        title: "Finish launch checklist",
        owner: "Mira",
        due_date: Date.to_iso8601(Date.add(today, -1)),
        due_date_known: true,
        status: "open",
        evidence_source_id: source["id"],
        evidence_text: "Mira will finish launch checklist by tomorrow."
      })

    commitment = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/briefs/daily", %{
        brief_date: Date.to_iso8601(today),
        window_days: 7
      })

    brief = json_response(conn, 200)
    assert brief["brief_type"] == "daily"
    assert brief["brief_date"] == Date.to_iso8601(today)
    assert brief["summary"] =~ "Pulse found"
    assert brief["what_changed_count"] >= 1
    assert brief["needs_attention_count"] >= 1

    what_changed = brief["sections"]["what_changed"]
    needs_attention = brief["sections"]["needs_attention"]
    assert Enum.any?(what_changed, &(&1["linked_entity_id"] == decision["id"]))
    assert Enum.any?(needs_attention, &(&1["linked_entity_id"] == commitment["id"]))

    item = Enum.find(what_changed, &(&1["linked_entity_id"] == decision["id"]))

    conn =
      get(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/briefs/#{brief["id"]}/items/#{item["id"]}/evidence"
      )

    assert [%{"source_id" => source_id}] = json_response(conn, 200)
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/briefs/latest")
    latest = json_response(conn, 200)
    assert latest["id"] == brief["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/briefs")
    assert [%{"id" => brief_id}] = json_response(conn, 200)
    assert brief_id == brief["id"]
  end

  test "meeting prep APIs create meetings and return grounded prep", %{conn: conn} do
    today = Date.utc_today()
    conn = post(conn, ~p"/api/workspaces", %{name: "Meeting API", root_path: "C:/tmp/mp-api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Meeting Prep Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        source_date: Date.to_iso8601(today),
        text_content:
          "The team decided to keep private beta scoped. Mira will finish launch checklist."
      })

    source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions", %{
        title: "Private beta scope",
        context: "Keep private beta scoped until readiness is clear.",
        decision_date: Date.to_iso8601(today),
        owner: "Mira",
        status: "active",
        evidence_source_id: source["id"],
        evidence_text: "The team decided to keep private beta scoped."
      })

    decision = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments", %{
        title: "Finish launch checklist",
        description: "Checklist gates the private beta launch.",
        owner: "Mira",
        due_date_known: false,
        status: "open",
        evidence_source_id: source["id"],
        evidence_text: "Mira will finish launch checklist."
      })

    commitment = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments", %{
        title: "Done launch follow-up",
        owner: "Mira",
        due_date_known: false,
        status: "done"
      })

    done_commitment = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/meetings", %{
        title: "Private beta launch review",
        meeting_date: Date.to_iso8601(today),
        description: "Review launch checklist and private beta scope.",
        attendees: ["Mira", "Rina"]
      })

    meeting = json_response(conn, 200)
    assert meeting["title"] == "Private beta launch review"

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/meetings/#{meeting["id"]}/prep")
    prep = json_response(conn, 200)
    assert prep["meeting"]["id"] == meeting["id"]
    assert [%{"id" => decision_id, "evidence" => [_]}] = prep["relevant_decisions"]
    assert decision_id == decision["id"]
    assert [%{"id" => commitment_id, "evidence" => [_]}] = prep["open_commitments"]
    assert commitment_id == commitment["id"]
    refute Enum.any?(prep["open_commitments"], &(&1["id"] == done_commitment["id"]))
    assert Enum.any?(prep["agenda_items"], &(&1["linked_entity_id"] == decision["id"]))
    assert Enum.any?(prep["agenda_items"], &(&1["linked_entity_id"] == commitment["id"]))

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/meetings/#{meeting["id"]}/prep/refresh")

    refreshed = json_response(conn, 200)
    assert Enum.any?(refreshed["meeting"]["decisions"], &(&1["id"] == decision["id"]))
    assert Enum.any?(refreshed["meeting"]["commitments"], &(&1["id"] == commitment["id"]))

    conn =
      delete(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/meetings/#{meeting["id"]}/commitments/#{commitment["id"]}"
      )

    unlinked = json_response(conn, 200)
    refute Enum.any?(unlinked["commitments"], &(&1["id"] == commitment["id"]))
  end

  test "risk radar and review inbox APIs support extraction review and approval", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "Risk API", root_path: "C:/tmp/rr-api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/risks", %{
        title: "Manual launch risk",
        description: "Known issue entered directly.",
        severity: "high",
        owner: "Mira",
        status: "open"
      })

    manual = json_response(conn, 200)
    assert manual["record_state"] == "accepted"
    assert manual["source_origin"] == "manual"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Decision API Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        text_content: "The team decided to keep beta scoped. Owner is Mira."
      })

    decision_source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Commitment API Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        text_content: "Action item: Mira will finish launch checklist."
      })

    commitment_source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Risk API Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        text_content: "Blocker: support coverage is blocking beta expansion; owner is Rina."
      })

    risk_source = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions/extract", %{
        source_id: decision_source["id"]
      })

    [decision] = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments/extract", %{
        source_id: commitment_source["id"]
      })

    [commitment] = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/risks/extract", %{
        source_id: risk_source["id"]
      })

    [risk] = json_response(conn, 200)
    assert risk["record_state"] == "suggested"
    assert risk["source_origin"] == "extracted"
    assert [%{"source_id" => source_id}] = risk["evidence"]
    assert source_id == risk_source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/review_inbox")
    inbox = json_response(conn, 200)
    assert Enum.map(inbox, & &1["type"]) |> Enum.sort() == ["commitment", "decision", "risk"]

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/review_inbox/risk/#{risk["id"]}", %{
        severity: "critical",
        owner: "Rina"
      })

    updated = json_response(conn, 200)
    assert updated["record"]["severity"] == "critical"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/review_inbox/risk/#{risk["id"]}/accept")

    accepted_risk = json_response(conn, 200)
    assert accepted_risk["record"]["record_state"] == "accepted"
    assert [%{"source_id" => source_id}] = accepted_risk["record"]["evidence"]
    assert source_id == risk_source["id"]

    conn =
      post(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/review_inbox/commitment/#{commitment["id"]}/reject"
      )

    rejected_commitment = json_response(conn, 200)
    assert rejected_commitment["record"]["record_state"] == "rejected"

    conn =
      post(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/review_inbox/decision/#{decision["id"]}/accept"
      )

    accepted_decision = json_response(conn, 200)
    assert accepted_decision["record"]["record_state"] == "accepted"

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/risks?severity=critical")
    accepted_risks = json_response(conn, 200)
    assert Enum.any?(accepted_risks, &(&1["id"] == risk["id"]))
    refute Enum.any?(accepted_risks, &(&1["id"] == manual["id"]))

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/review_inbox")
    assert json_response(conn, 200) == []
  end

  test "project dashboard reflects real source ask decision commitment brief flow", %{conn: conn} do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    conn = post(conn, ~p"/api/workspaces", %{name: "Dashboard API", root_path: "C:/tmp/pd-api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Dashboard Demo Source",
        source_type: "meeting_note",
        origin: "manual_entry",
        source_date: Date.to_iso8601(today),
        text_content:
          "Launch update: the team decided to keep private beta scoped until support readiness is clear. Mira will finish the launch checklist before beta expansion."
      })

    source = json_response(conn, 200)
    assert source["processing_status"] == "ready"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/ask", %{
        question: "What is the launch plan?"
      })

    answer = json_response(conn, 200)
    assert [_citation | _] = answer["citations"]
    citation = List.first(answer["citations"])

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/decisions", %{
        title: "Keep private beta scoped",
        context: "Private beta remains scoped until support readiness is clear.",
        decision_date: Date.to_iso8601(today),
        owner: "Mira",
        status: "active",
        evidence_source_id: citation["source_id"],
        evidence_text: citation["quote"]
      })

    decision = json_response(conn, 200)
    assert decision["record_state"] == "accepted"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/commitments", %{
        title: "Finish launch checklist",
        description: "Complete the launch checklist before beta expansion.",
        owner: "Mira",
        due_date: Date.to_iso8601(yesterday),
        due_date_known: true,
        status: "open",
        evidence_source_id: citation["source_id"],
        evidence_text: citation["quote"]
      })

    commitment = json_response(conn, 200)
    assert commitment["record_state"] == "accepted"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/briefs/daily", %{
        brief_date: Date.to_iso8601(today),
        window_days: 7
      })

    brief = json_response(conn, 200)

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/dashboard")
    dashboard = json_response(conn, 200)

    assert dashboard["latest_brief"]["id"] == brief["id"]
    assert Enum.any?(dashboard["recent_decisions"], &(&1["id"] == decision["id"]))
    assert Enum.any?(dashboard["overdue_commitments"], &(&1["id"] == commitment["id"]))
    assert dashboard["open_risks"] == []
    assert dashboard["summary"] =~ "Dashboard status"
  end
end
