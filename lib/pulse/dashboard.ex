defmodule Pulse.Dashboard do
  alias Pulse.Briefs
  alias Pulse.Commitments
  alias Pulse.Decisions
  alias Pulse.Risks

  @recent_limit 5
  @attention_limit 6
  @severity_rank %{"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}

  def get(workspace_id) do
    latest_brief = Briefs.latest_daily_brief(workspace_id)
    recent_decisions = Decisions.list_accepted(workspace_id) |> Enum.take(@recent_limit)
    accepted_commitments = Commitments.list_accepted(workspace_id)

    overdue_commitments =
      accepted_commitments |> Enum.filter(&overdue?/1) |> Enum.take(@attention_limit)

    open_risks =
      workspace_id
      |> Risks.list_accepted(%{"status" => "open"})
      |> Enum.sort_by(&risk_sort/1)
      |> Enum.take(@attention_limit)

    %{
      latest_brief: latest_brief,
      recent_decisions: recent_decisions,
      overdue_commitments: overdue_commitments,
      open_risks: open_risks,
      summary: summary(latest_brief, recent_decisions, overdue_commitments, open_risks)
    }
  end

  def overdue?(commitment) do
    commitment.record_state == "accepted" and commitment.status != "done" and
      (commitment.status == "overdue" or past_due?(commitment))
  end

  defp past_due?(commitment) do
    commitment.due_date_known and not is_nil(commitment.due_date) and
      Date.compare(commitment.due_date, Date.utc_today()) == :lt
  end

  defp risk_sort(risk) do
    {Map.get(@severity_rank, risk.severity, 9), DateTime.to_unix(risk.updated_at) * -1}
  end

  defp summary(nil, [], [], []) do
    "No accepted project truth is available yet. Add a ready source, ask with citations, accept records, then generate a Daily Brief."
  end

  defp summary(brief, decisions, commitments, risks) do
    brief_text =
      if brief do
        brief.summary
      else
        "No Daily Brief has been generated yet."
      end

    "#{brief_text} Dashboard status: #{length(decisions)} recent decision#{plural(decisions)}, #{length(commitments)} overdue commitment#{plural(commitments)}, and #{length(risks)} open risk#{plural(risks)}."
  end

  defp plural([_one]), do: ""
  defp plural(_items), do: "s"
end
