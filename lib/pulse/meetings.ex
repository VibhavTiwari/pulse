defmodule Pulse.Meetings do
  import Ecto.Query

  alias Pulse.Commitments
  alias Pulse.Commitments.Commitment
  alias Pulse.Decisions
  alias Pulse.Evidence
  alias Pulse.Meetings.Meeting
  alias Pulse.Repo

  @open_commitment_statuses ~w(open blocked overdue)
  @fallback_limit 5

  def list_meetings(workspace_id, filters \\ %{}) do
    Meeting
    |> where([m], m.workspace_id == ^workspace_id)
    |> apply_filters(filters)
    |> order_by([m], desc: m.meeting_date, desc: m.inserted_at)
    |> Repo.all()
  end

  def get_meeting!(workspace_id, id) do
    Meeting
    |> where([m], m.workspace_id == ^workspace_id and m.id == ^id)
    |> Repo.one!()
    |> Repo.preload([:decisions, :commitments])
  end

  def create_meeting(workspace_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("workspace_id", workspace_id)

    %Meeting{}
    |> Meeting.changeset(attrs)
    |> Repo.insert()
  end

  def update_meeting(%Meeting{} = meeting, attrs) do
    meeting
    |> Meeting.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  def get_prep(workspace_id, meeting_id) do
    meeting = get_meeting!(workspace_id, meeting_id)
    decisions = relevant_decisions(meeting)
    commitments = relevant_commitments(meeting)

    %{
      meeting: meeting,
      relevant_decisions: decisions,
      open_commitments: commitments,
      agenda_items: agenda_items(meeting, decisions, commitments)
    }
  end

  def refresh_prep(workspace_id, meeting_id) do
    prep = get_prep(workspace_id, meeting_id)

    Enum.each(prep.relevant_decisions, fn decision ->
      insert_link(
        "meeting_decisions",
        :meeting_id,
        prep.meeting.id,
        :decision_id,
        decision.id,
        workspace_id
      )
    end)

    Enum.each(prep.open_commitments, fn commitment ->
      insert_link(
        "meeting_commitments",
        :meeting_id,
        prep.meeting.id,
        :commitment_id,
        commitment.id,
        workspace_id
      )
    end)

    get_prep(workspace_id, meeting_id)
  end

  def link_decision(%Meeting{} = meeting, decision_id) do
    decision = Decisions.get_decision!(meeting.workspace_id, decision_id)

    if decision.record_state == "accepted" do
      insert_link(
        "meeting_decisions",
        :meeting_id,
        meeting.id,
        :decision_id,
        decision.id,
        meeting.workspace_id
      )

      {:ok, get_meeting!(meeting.workspace_id, meeting.id)}
    else
      {:error, :decision_not_accepted}
    end
  end

  def unlink_decision(%Meeting{} = meeting, decision_id) do
    delete_link("meeting_decisions", :meeting_id, meeting.id, :decision_id, decision_id)
    {:ok, get_meeting!(meeting.workspace_id, meeting.id)}
  end

  def link_commitment(%Meeting{} = meeting, commitment_id) do
    commitment = Commitments.get_commitment!(meeting.workspace_id, commitment_id)

    cond do
      commitment.record_state != "accepted" ->
        {:error, :commitment_not_accepted}

      commitment.status == "done" ->
        {:error, :commitment_done}

      true ->
        insert_link(
          "meeting_commitments",
          :meeting_id,
          meeting.id,
          :commitment_id,
          commitment.id,
          meeting.workspace_id
        )

        {:ok, get_meeting!(meeting.workspace_id, meeting.id)}
    end
  end

  def unlink_commitment(%Meeting{} = meeting, commitment_id) do
    delete_link("meeting_commitments", :meeting_id, meeting.id, :commitment_id, commitment_id)
    {:ok, get_meeting!(meeting.workspace_id, meeting.id)}
  end

  defp relevant_decisions(%Meeting{} = meeting) do
    linked =
      meeting.decisions
      |> Enum.filter(&(&1.record_state == "accepted"))
      |> Enum.map(&with_evidence(&1, "decision"))

    automatic =
      meeting.workspace_id
      |> Decisions.list_accepted()
      |> Enum.filter(&relevant_record?(meeting, "#{&1.title} #{&1.context} #{&1.owner}"))
      |> Enum.map(&with_evidence(&1, "decision"))

    (linked ++ automatic)
    |> unique_records()
    |> fallback_records(fn ->
      meeting.workspace_id
      |> Decisions.list_accepted()
      |> Enum.take(@fallback_limit)
      |> Enum.map(&with_evidence(&1, "decision"))
    end)
  end

  defp relevant_commitments(%Meeting{} = meeting) do
    linked =
      meeting.commitments
      |> Enum.filter(&open_commitment?/1)
      |> Enum.map(&with_evidence(&1, "commitment"))

    automatic =
      meeting.workspace_id
      |> Commitments.list_accepted()
      |> Enum.filter(&open_commitment?/1)
      |> Enum.filter(&relevant_record?(meeting, "#{&1.title} #{&1.description} #{&1.owner}"))
      |> Enum.map(&with_evidence(&1, "commitment"))

    (linked ++ automatic)
    |> unique_records()
    |> fallback_records(fn ->
      meeting.workspace_id
      |> Commitments.list_accepted()
      |> Enum.filter(&(&1.status == "open"))
      |> Enum.take(@fallback_limit)
      |> Enum.map(&with_evidence(&1, "commitment"))
    end)
  end

  defp agenda_items(meeting, decisions, commitments) do
    decision_items =
      Enum.map(decisions, fn decision ->
        %{
          "title" => "Review decision: #{decision.title}",
          "reason" =>
            "This accepted decision appears relevant to #{meeting.title} and may shape the discussion.",
          "linked_entity_type" => "decision",
          "linked_entity_id" => decision.id,
          "evidence_state" => evidence_state(decision)
        }
      end)

    commitment_items =
      Enum.map(commitments, fn commitment ->
        due =
          if commitment.due_date_known and commitment.due_date,
            do: Date.to_iso8601(commitment.due_date),
            else: "unknown"

        %{
          "title" => "Follow up: #{commitment.title}",
          "reason" =>
            "#{commitment.owner} owns this #{commitment.status} commitment. Due date: #{due}.",
          "linked_entity_type" => "commitment",
          "linked_entity_id" => commitment.id,
          "evidence_state" => evidence_state(commitment)
        }
      end)

    context_items =
      if context_tokens(meeting) == [] do
        []
      else
        [
          %{
            "title" => "Clarify meeting outcome",
            "reason" => "The meeting context says: #{meeting.description || meeting.title}",
            "linked_entity_type" => "meeting",
            "linked_entity_id" => meeting.id,
            "evidence_state" => "none"
          }
        ]
      end

    case decision_items ++ commitment_items ++ context_items do
      [] ->
        [
          %{
            "title" => "Not enough project context",
            "reason" =>
              "Pulse did not find accepted decisions, open commitments, or meeting context strong enough to suggest agenda topics.",
            "evidence_state" => "none"
          }
        ]

      items ->
        Enum.take(items, 8)
    end
  end

  defp relevant_record?(meeting, record_text) do
    tokens = context_tokens(meeting)
    tokens != [] and Enum.any?(tokens, &String.contains?(normalize(record_text), &1))
  end

  defp context_tokens(%Meeting{} = meeting) do
    "#{meeting.title} #{meeting.description}"
    |> normalize()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.reject(
      &(&1 in ["meeting", "sync", "weekly", "daily", "review", "standup", "prep", "project"])
    )
    |> Enum.uniq()
  end

  defp fallback_records([], fun), do: fun.()
  defp fallback_records(records, _fun), do: records

  defp open_commitment?(%Commitment{} = commitment) do
    commitment.record_state == "accepted" and commitment.status in @open_commitment_statuses
  end

  defp with_evidence(record, type) do
    Map.put(record, :evidence, Evidence.list_for_record(type, record.id))
  end

  defp evidence_state(record) do
    if Map.has_key?(record, :evidence) and record.evidence != [], do: "strong", else: "none"
  end

  defp unique_records(records), do: Enum.uniq_by(records, & &1.id)

  defp apply_filters(query, filters) do
    Enum.reduce([:meeting_date], query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [m], field(m, ^field) == ^value)
    end)
  end

  defp insert_link(table, left_key, left_id, right_key, right_id, workspace_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      table,
      [
        %{workspace_id: dump_uuid(workspace_id), inserted_at: now}
        |> Map.put(left_key, dump_uuid(left_id))
        |> Map.put(right_key, dump_uuid(right_id))
      ],
      on_conflict: :nothing
    )
  end

  defp delete_link(table, left_key, left_id, right_key, right_id) do
    left_id = dump_uuid(left_id)
    right_id = dump_uuid(right_id)

    Repo.delete_all(
      from l in table,
        where: field(l, ^left_key) == ^left_id and field(l, ^right_key) == ^right_id
    )
  end

  defp dump_uuid(id) do
    {:ok, dumped} = Ecto.UUID.dump(id)
    dumped
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
