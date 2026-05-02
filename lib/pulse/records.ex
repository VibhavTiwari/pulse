defmodule Pulse.Records do
  import Ecto.Query

  alias Pulse.Repo

  @schemas %{
    "decision" => Pulse.Decisions.Decision,
    "commitment" => Pulse.Commitments.Commitment,
    "risk" => Pulse.Risks.Risk,
    "meeting" => Pulse.Meetings.Meeting,
    "brief" => Pulse.Briefs.Brief
  }

  @join_tables %{
    {"meeting", "decision"} => {"meeting_decisions", :meeting_id, :decision_id},
    {"meeting", "commitment"} => {"meeting_commitments", :meeting_id, :commitment_id},
    {"meeting", "risk"} => {"meeting_risks", :meeting_id, :risk_id},
    {"brief", "decision"} => {"brief_decisions", :brief_id, :decision_id},
    {"brief", "commitment"} => {"brief_commitments", :brief_id, :commitment_id},
    {"brief", "risk"} => {"brief_risks", :brief_id, :risk_id},
    {"brief", "meeting"} => {"brief_meetings", :brief_id, :meeting_id}
  }

  def schema!(type), do: Map.fetch!(@schemas, type)

  def get(type, id), do: Repo.get(schema!(type), id)

  def get!(type, id) do
    schema!(type)
    |> Repo.get!(id)
    |> preload_links(type)
  end

  def list(type, workspace_id, filters \\ %{}) do
    schema = schema!(type)

    schema
    |> where([r], r.workspace_id == ^workspace_id)
    |> maybe_default_record_state(type, filters)
    |> apply_filters(type, filters)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  def create(type, workspace_id, attrs) do
    attrs = attrs |> stringify_keys() |> Map.put("workspace_id", workspace_id)
    schema = schema!(type)
    schema.changeset(struct(schema), attrs) |> Repo.insert()
  end

  def update(type, record, attrs) do
    schema = schema!(type)
    schema.changeset(record, stringify_keys(attrs)) |> Repo.update()
  end

  def transition_state(type, record, state) when state in ["accepted", "rejected", "suggested"] do
    __MODULE__.update(type, record, %{"record_state" => state})
  end

  def link(parent_type, parent_id, child_type, child_id) do
    {table, parent_key, child_key} = Map.fetch!(@join_tables, {parent_type, child_type})
    parent = get!(parent_type, parent_id)
    child = get!(child_type, child_id)

    if parent.workspace_id != child.workspace_id do
      {:error, :workspace_mismatch}
    else
      now = DateTime.utc_now(:second)

      Repo.insert_all(
        table,
        [
          %{}
          |> Map.put(:workspace_id, dump_uuid(parent.workspace_id))
          |> Map.put(parent_key, dump_uuid(parent_id))
          |> Map.put(child_key, dump_uuid(child_id))
          |> Map.put(:inserted_at, now)
        ],
        on_conflict: :nothing
      )

      {:ok, get!(parent_type, parent_id)}
    end
  end

  defp preload_links(record, "meeting"),
    do: Repo.preload(record, [:decisions, :commitments, :risks])

  defp preload_links(record, "brief"),
    do: Repo.preload(record, [:decisions, :commitments, :risks, :meetings])

  defp preload_links(record, _type), do: record

  defp maybe_default_record_state(query, type, filters)
       when type in ["decision", "commitment", "risk"] do
    state = filters["record_state"] || filters[:record_state] || "accepted"
    where(query, [r], r.record_state == ^state)
  end

  defp maybe_default_record_state(query, _type, _filters), do: query

  defp apply_filters(query, type, filters) do
    allowed =
      case type do
        "decision" -> [:status, :owner]
        "commitment" -> [:status, :owner, :due_date]
        "risk" -> [:severity, :status, :owner]
        "meeting" -> [:meeting_date]
        "brief" -> [:brief_date, :brief_type]
      end

    Enum.reduce(allowed, query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [r], field(r, ^field) == ^value)
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp dump_uuid(id) do
    {:ok, dumped} = Ecto.UUID.dump(id)
    dumped
  end
end
