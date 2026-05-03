defmodule Pulse.DashboardTest do
  use Pulse.DataCase

  alias Pulse.{Briefs, Commitments, Dashboard, Decisions, Records, Risks, Workspaces}

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{"name" => "Dashboard Workspace", "root_path" => "C:/tmp/pd"})

    %{workspace: workspace, today: Date.utc_today()}
  end

  test "dashboard handles empty project truth honestly", %{workspace: workspace} do
    dashboard = Dashboard.get(workspace.id)

    assert dashboard.latest_brief == nil
    assert dashboard.recent_decisions == []
    assert dashboard.overdue_commitments == []
    assert dashboard.open_risks == []
    assert dashboard.summary =~ "No accepted project truth"
  end

  test "dashboard shows accepted truth and excludes suggested rejected and other workspaces", %{
    workspace: workspace,
    today: today
  } do
    {:ok, latest_brief} = Briefs.generate_daily_brief(workspace.id, %{"brief_date" => today})

    {:ok, older_decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Older decision",
        "context" => "Older accepted context.",
        "decision_date" => Date.add(today, -2),
        "owner" => "Mira",
        "status" => "active"
      })

    {:ok, recent_decision} =
      Decisions.create_manual_decision(workspace.id, %{
        "title" => "Recent decision",
        "context" => "Recent accepted context.",
        "decision_date" => today,
        "owner" => "Mira",
        "status" => "active"
      })

    {:ok, _suggested_decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Suggested dashboard decision",
        "context" => "Should not appear.",
        "decision_date" => today,
        "owner" => "Dev",
        "status" => "active",
        "record_state" => "suggested"
      })

    {:ok, _rejected_decision} =
      Records.create("decision", workspace.id, %{
        "title" => "Rejected dashboard decision",
        "context" => "Should not appear.",
        "decision_date" => today,
        "owner" => "Dev",
        "status" => "active",
        "record_state" => "rejected"
      })

    {:ok, overdue} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Late checklist",
        "owner" => "Mira",
        "due_date" => Date.add(today, -1),
        "due_date_known" => true,
        "status" => "open"
      })

    {:ok, _done_past_due} =
      Commitments.create_manual_commitment(workspace.id, %{
        "title" => "Done past due",
        "owner" => "Mira",
        "due_date" => Date.add(today, -3),
        "due_date_known" => true,
        "status" => "done"
      })

    {:ok, _suggested_overdue} =
      Records.create("commitment", workspace.id, %{
        "title" => "Suggested late checklist",
        "owner" => "Dev",
        "due_date" => Date.add(today, -1),
        "due_date_known" => true,
        "status" => "overdue",
        "record_state" => "suggested"
      })

    {:ok, _rejected_overdue} =
      Records.create("commitment", workspace.id, %{
        "title" => "Rejected late checklist",
        "owner" => "Dev",
        "due_date" => Date.add(today, -1),
        "due_date_known" => true,
        "status" => "overdue",
        "record_state" => "rejected"
      })

    {:ok, open_risk} =
      Risks.create_manual_risk(workspace.id, %{
        "title" => "Critical support risk",
        "description" => "Support readiness is blocking expansion.",
        "severity" => "critical",
        "owner" => "Rina",
        "status" => "open"
      })

    {:ok, _resolved_risk} =
      Risks.create_manual_risk(workspace.id, %{
        "title" => "Resolved support risk",
        "description" => "This should not appear.",
        "severity" => "critical",
        "owner" => "Rina",
        "status" => "resolved"
      })

    {:ok, _suggested_risk} =
      Records.create("risk", workspace.id, %{
        "title" => "Suggested support risk",
        "description" => "Should not appear.",
        "severity" => "critical",
        "owner" => "Rina",
        "status" => "open",
        "record_state" => "suggested"
      })

    {:ok, _rejected_risk} =
      Records.create("risk", workspace.id, %{
        "title" => "Rejected support risk",
        "description" => "Should not appear.",
        "severity" => "critical",
        "owner" => "Rina",
        "status" => "open",
        "record_state" => "rejected"
      })

    {:ok, other_workspace} =
      Workspaces.create_workspace(%{
        "name" => "Other Dashboard",
        "root_path" => "C:/tmp/other-pd"
      })

    {:ok, _other_risk} =
      Risks.create_manual_risk(other_workspace.id, %{
        "title" => "Other workspace risk",
        "description" => "Should not leak.",
        "severity" => "critical",
        "owner" => "Other",
        "status" => "open"
      })

    dashboard = Dashboard.get(workspace.id)

    assert dashboard.latest_brief.id == latest_brief.id

    assert Enum.map(dashboard.recent_decisions, & &1.id) == [
             recent_decision.id,
             older_decision.id
           ]

    assert [%{id: overdue_id}] = dashboard.overdue_commitments
    assert overdue_id == overdue.id
    assert [%{id: risk_id}] = dashboard.open_risks
    assert risk_id == open_risk.id
    refute dashboard.summary =~ "Suggested dashboard decision"
    refute Enum.any?(dashboard.recent_decisions, &(&1.title == "Rejected dashboard decision"))
    refute Enum.any?(dashboard.overdue_commitments, &(&1.title == "Suggested late checklist"))
    refute Enum.any?(dashboard.overdue_commitments, &(&1.title == "Rejected late checklist"))
    refute Enum.any?(dashboard.open_risks, &(&1.title == "Suggested support risk"))
    refute Enum.any?(dashboard.open_risks, &(&1.title == "Rejected support risk"))
    refute Enum.any?(dashboard.open_risks, &(&1.title == "Other workspace risk"))
  end
end
