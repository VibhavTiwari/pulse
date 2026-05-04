defmodule Pulse.ProjectMemory do
  import Ecto.Query

  alias Pulse.Commitments.Commitment
  alias Pulse.Commitments
  alias Pulse.Decisions
  alias Pulse.Decisions.Decision
  alias Pulse.Intelligence
  alias Pulse.Repo

  @default_limit 4

  def relevant(workspace_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    tokens = Intelligence.tokenize(query)

    %{
      decisions:
        workspace_id
        |> accepted_decisions()
        |> rank_records(tokens, &decision_text/1)
        |> Enum.take(limit)
        |> Enum.map(&Decisions.with_evidence/1),
      commitments:
        workspace_id
        |> accepted_commitments()
        |> rank_records(tokens, &commitment_text/1)
        |> Enum.take(limit)
        |> Enum.map(&Commitments.with_evidence/1)
    }
  end

  def current_decisions(workspace_id) do
    Decision
    |> where(
      [d],
      d.workspace_id == ^workspace_id and d.record_state == "accepted" and
        d.decision_state in ["accepted", "proposed"]
    )
    |> order_by([d], desc: d.decision_date, desc: d.inserted_at)
    |> Repo.all()
    |> Enum.map(&Decisions.with_evidence/1)
  end

  defp accepted_decisions(workspace_id) do
    Decision
    |> where([d], d.workspace_id == ^workspace_id and d.record_state == "accepted")
    |> order_by([d], desc: d.decision_date, desc: d.inserted_at)
    |> Repo.all()
  end

  defp accepted_commitments(workspace_id) do
    Commitment
    |> where([c], c.workspace_id == ^workspace_id and c.record_state == "accepted")
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  defp rank_records(records, [], text_fun), do: Enum.filter(records, &(text_fun.(&1) != ""))

  defp rank_records(records, tokens, text_fun) do
    records
    |> Enum.map(fn record -> {record, token_score(text_fun.(record), tokens)} end)
    |> Enum.filter(fn {_record, score} -> score > 0 end)
    |> Enum.sort_by(fn {_record, score} -> -score end)
    |> Enum.map(fn {record, _score} -> record end)
  end

  defp token_score(text, tokens) do
    lower = String.downcase(text)
    Enum.count(tokens, &String.contains?(lower, &1))
  end

  defp decision_text(decision) do
    [
      decision.title,
      decision.context,
      decision.owner,
      decision.decision_state,
      decision.rationale,
      decision.tradeoffs,
      decision.alternatives_considered,
      decision.reversal_reason
    ]
    |> Enum.join(" ")
  end

  defp commitment_text(commitment) do
    [
      commitment.title,
      commitment.description,
      commitment.owner,
      commitment.status,
      commitment.due_date
    ]
    |> Enum.join(" ")
  end
end
