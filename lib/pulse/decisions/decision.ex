defmodule Pulse.Decisions.Decision do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @statuses ~w(active inactive)
  @source_origins ~w(manual extracted)
  @decision_states ~w(proposed accepted reversed superseded)

  def decision_states, do: @decision_states

  schema "decisions" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :superseded_by_decision, __MODULE__
    has_many :superseded_decisions, __MODULE__, foreign_key: :superseded_by_decision_id

    field :title, :string
    field :context, :string
    field :decision_date, :date
    field :owner, :string
    field :status, :string, default: "active"
    field :record_state, :string, default: "accepted"
    field :source_origin, :string
    field :decision_state, :string, default: "accepted"
    field :reversal_reason, :string
    field :rationale, :string
    field :tradeoffs, :string
    field :alternatives_considered, :string

    timestamps()
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :workspace_id,
      :title,
      :context,
      :decision_date,
      :owner,
      :status,
      :record_state,
      :source_origin,
      :decision_state,
      :superseded_by_decision_id,
      :reversal_reason,
      :rationale,
      :tradeoffs,
      :alternatives_considered
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :title,
      :context,
      :decision_date,
      :owner,
      :status,
      :record_state,
      :decision_state
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_record_state()
    |> validate_inclusion(:source_origin, @source_origins)
    |> validate_inclusion(:decision_state, @decision_states)
    |> validate_supersession_fields()
  end

  defp validate_supersession_fields(changeset) do
    decision_state = get_field(changeset, :decision_state)
    id = get_field(changeset, :id)
    superseded_by_id = get_field(changeset, :superseded_by_decision_id)

    changeset
    |> validate_change(:superseded_by_decision_id, fn
      :superseded_by_decision_id, ^id when not is_nil(id) ->
        [superseded_by_decision_id: "cannot reference itself"]

      _field, _value ->
        []
    end)
    |> then(fn changeset ->
      if decision_state == "superseded" and is_nil(superseded_by_id) do
        add_error(changeset, :superseded_by_decision_id, "is required when superseded")
      else
        changeset
      end
    end)
  end
end
