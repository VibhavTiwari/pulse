defmodule Pulse.ReviewInbox do
  alias Pulse.Commitments
  alias Pulse.Decisions
  alias Pulse.Risks

  def list_suggestions(workspace_id, filters \\ %{}) do
    type = filters["type"] || filters[:type] || "all"

    []
    |> maybe_add(type, "decision", fn -> Decisions.list_suggested(workspace_id) end)
    |> maybe_add(type, "commitment", fn -> Commitments.list_suggested(workspace_id) end)
    |> maybe_add(type, "risk", fn -> Risks.list_suggested(workspace_id) end)
    |> Enum.sort_by(& &1.record.inserted_at, {:desc, DateTime})
  end

  def get_suggestion!(workspace_id, type, id) do
    record = get_record!(workspace_id, type, id)

    if record.record_state == "suggested" do
      item(type, record)
    else
      raise Ecto.NoResultsError, queryable: type
    end
  end

  def update_suggestion(workspace_id, type, id, attrs) do
    record = get_record!(workspace_id, type, id)

    case type do
      "decision" -> Decisions.update_decision(record, attrs)
      "commitment" -> Commitments.update_commitment(record, attrs)
      "risk" -> Risks.update_risk(record, attrs)
    end
  end

  def accept_suggestion(workspace_id, type, id) do
    record = get_record!(workspace_id, type, id)

    case type do
      "decision" -> Decisions.accept_decision(record)
      "commitment" -> Commitments.accept_commitment(record)
      "risk" -> Risks.accept_risk(record)
    end
  end

  def reject_suggestion(workspace_id, type, id) do
    record = get_record!(workspace_id, type, id)

    case type do
      "decision" -> Decisions.reject_decision(record)
      "commitment" -> Commitments.reject_commitment(record)
      "risk" -> Risks.reject_risk(record)
    end
  end

  defp maybe_add(items, filter_type, item_type, fun) when filter_type in ["all", item_type] do
    items ++ Enum.map(fun.(), &item(item_type, &1))
  end

  defp maybe_add(items, _filter_type, _item_type, _fun), do: items

  defp item(type, record) do
    %{
      type: type,
      id: record.id,
      record: record,
      evidence_count: evidence_count(record),
      incomplete: incomplete?(type, record)
    }
  end

  defp get_record!(workspace_id, "decision", id), do: Decisions.get_decision!(workspace_id, id)

  defp get_record!(workspace_id, "commitment", id),
    do: Commitments.get_commitment!(workspace_id, id)

  defp get_record!(workspace_id, "risk", id), do: Risks.get_risk!(workspace_id, id)

  defp evidence_count(record) do
    if Map.has_key?(record, :evidence) and is_list(record.evidence),
      do: length(record.evidence),
      else: 0
  end

  defp incomplete?("decision", record) do
    blank?(record.title) or blank?(record.context) or blank?(record.owner) or
      blank?(record.status) or is_nil(record.decision_date) or unknown_owner?(record.owner)
  end

  defp incomplete?("commitment", record) do
    blank?(record.title) or blank?(record.owner) or blank?(record.status) or
      unknown_owner?(record.owner) or (record.due_date_known == true and is_nil(record.due_date))
  end

  defp incomplete?("risk", record) do
    blank?(record.title) or blank?(record.description) or blank?(record.severity) or
      blank?(record.owner) or blank?(record.status) or unknown_owner?(record.owner)
  end

  defp unknown_owner?(owner), do: String.downcase(String.trim(owner || "")) == "unknown"
  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
