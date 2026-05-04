defmodule Pulse.AskTest do
  use Pulse.DataCase

  alias Pulse.{Ask, Commitments, Decisions, Repo, Sources, Workspaces}
  alias Pulse.Ask.{AnswerCitation, Message}

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Ask Workspace", "root_path" => "C:/tmp/ask"})

    %{workspace: workspace}
  end

  test "answerable questions store a thread, messages, and citations", %{workspace: workspace} do
    {:ok, _source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Evidence",
        "source_type" => "document",
        "origin" => "manual_entry",
        "text_content" =>
          "The launch plan is a focused private beta before public announcement. The owner is Mira."
      })

    {:ok, answer} = Ask.ask(workspace.id, "What is the launch plan?")

    assert answer.evidence_state == "strong"
    assert answer.answer =~ "private beta"
    assert [%{source_title: "Launch Evidence", quote: quote}] = answer.citations
    assert quote =~ "private beta"

    thread = Ask.get_thread!(workspace.id, answer.thread_id)
    assert [%{role: "user"}, %{role: "assistant", evidence_state: "strong"}] = thread.messages
  end

  test "missing evidence produces no-evidence answer with no citations", %{workspace: workspace} do
    {:ok, answer} = Ask.ask(workspace.id, "What is the pricing model?")

    assert answer.evidence_state == "none"
    assert answer.answer =~ "do not have enough evidence"
    assert answer.citations == []
  end

  test "weak evidence is cautious and cited", %{workspace: workspace} do
    {:ok, _source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Risk Snippet",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Capacity was mentioned once in the project notes."
      })

    {:ok, answer} = Ask.ask(workspace.id, "Capacity?")

    assert answer.evidence_state == "weak"
    assert answer.answer =~ "only partially address"
    assert [_citation] = answer.citations
  end

  test "conflicting evidence is marked mixed and cites evidence", %{workspace: workspace} do
    {:ok, _source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Risk Conflict",
        "source_type" => "transcript",
        "origin" => "manual_entry",
        "text_content" =>
          "The rollout risk is high because capacity is constrained.\n\nThe rollout risk is low because capacity was added."
      })

    {:ok, answer} = Ask.ask(workspace.id, "What is the rollout risk?")

    assert answer.evidence_state == "mixed"
    assert answer.answer =~ "sources appear to conflict"
    assert [_citation | _] = answer.citations
  end

  test "follow-up questions stay in the same workspace thread", %{workspace: workspace} do
    {:ok, _source} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Owner",
        "source_type" => "meeting_note",
        "origin" => "manual_entry",
        "text_content" => "The launch owner is Mira. The launch plan is a private beta."
      })

    {:ok, first} = Ask.ask(workspace.id, "What is the launch plan?")
    {:ok, follow_up} = Ask.ask(workspace.id, "Who owns it?", thread_id: first.thread_id)

    assert follow_up.thread_id == first.thread_id
    assert follow_up.answer =~ "Mira"

    thread = Ask.get_thread!(workspace.id, first.thread_id)
    assert Enum.map(thread.messages, & &1.role) == ["user", "assistant", "user", "assistant"]
  end

  test "citation changeset rejects cross-workspace evidence", %{workspace: workspace} do
    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other Ask", "root_path" => "C:/tmp/other"})

    {:ok, source} =
      Sources.create_text_source(other_workspace.id, %{
        "title" => "Other Source",
        "source_type" => "note",
        "origin" => "manual_entry",
        "text_content" => "Other workspace evidence."
      })

    [passage] = Pulse.Intelligence.search(other_workspace.id, "workspace evidence")

    {:ok, answer} = Ask.ask(workspace.id, "Anything?")

    message = Repo.get!(Message, answer.answer_id)

    changeset =
      AnswerCitation.changeset(%AnswerCitation{}, %{
        workspace_id: workspace.id,
        ask_message_id: message.id,
        source_id: source.id,
        source_passage_id: passage.source_passage_id
      })

    refute changeset.valid?
    assert %{source_id: ["is invalid"], source_passage_id: ["is invalid"]} = errors_on(changeset)
  end

  test "answers use accepted project memory and expose project-record evidence", %{
    workspace: workspace
  } do
    {:ok, decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Keep launch in private beta",
        "context" => "Public launch waits until support readiness is proven.",
        "decision_date" => "2026-05-03",
        "owner" => "Mira",
        "status" => "active",
        "rationale" => "Support coverage is the launch constraint",
        "tradeoffs" => "Slower growth in exchange for safer onboarding"
      })

    {:ok, commitment} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Prepare support readiness checklist",
        "description" => "Mira owns the support checklist before launch expansion.",
        "owner" => "Mira",
        "due_date_known" => false,
        "status" => "open"
      })

    {:ok, rejected} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Rejected public launch",
        "context" => "This should not become project memory.",
        "decision_date" => "2026-05-03",
        "owner" => "Rina",
        "status" => "active"
      })

    {:ok, _rejected} = Decisions.reject_decision(%{rejected | record_state: "suggested"})

    {:ok, answer} = Ask.ask(workspace.id, "What was decided about launch and who owns support?")

    assert answer.evidence_state == "strong"
    assert answer.answer =~ "Accepted decision"
    assert answer.answer =~ "Accepted commitment"
    assert answer.answer =~ "Rationale"
    refute answer.answer =~ "Rejected public launch"

    assert Enum.any?(
             answer.citations,
             &(&1.citation_kind == "project_record" and &1.project_record_id == decision.id)
           )

    assert Enum.any?(
             answer.citations,
             &(&1.citation_kind == "project_record" and &1.project_record_id == commitment.id)
           )

    evidence = Ask.get_answer_evidence!(workspace.id, answer.answer_id)
    assert evidence.evidence_state == "strong"
    assert Enum.all?(evidence.citations, &(&1.citation_kind == "project_record"))
  end

  test "compare sources requires ready same-workspace sources and returns evidence-backed findings",
       %{
         workspace: workspace
       } do
    {:ok, earlier} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Update 1",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" => "Support readiness is blocked. Mira owns the checklist."
      })

    {:ok, later} =
      Sources.create_text_source(workspace.id, %{
        "title" => "Launch Update 2",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" =>
          "Support readiness is unblocked. Mira owns the checklist. Rina will staff support."
      })

    assert {:ok, comparison} =
             Ask.compare_sources(workspace.id, [earlier.id, later.id], "What changed?")

    assert comparison.evidence_state in ["strong", "mixed"]
    assert Enum.any?(comparison.findings, &(&1.finding_type in ["added", "conflict"]))
    assert Enum.any?(comparison.findings, &(&1.evidence != []))

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{"name" => "Other Compare", "root_path" => "C:/tmp/compare"})

    {:ok, other_source} =
      Sources.create_text_source(other_workspace.id, %{
        "title" => "Other Update",
        "source_type" => "project_update",
        "origin" => "manual_entry",
        "text_content" => "Other workspace launch update."
      })

    assert {:error, :source_not_found} =
             Ask.compare_sources(workspace.id, [earlier.id, other_source.id], "What changed?")
  end
end
