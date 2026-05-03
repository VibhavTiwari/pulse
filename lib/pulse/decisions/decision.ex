defmodule Pulse.Decisions.Decision do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @statuses ~w(active inactive)
  @source_origins ~w(manual extracted)

  schema "decisions" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :context, :string
    field :decision_date, :date
    field :owner, :string
    field :status, :string, default: "active"
    field :record_state, :string, default: "accepted"
    field :source_origin, :string

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
      :source_origin
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :title,
      :context,
      :decision_date,
      :owner,
      :status,
      :record_state
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_record_state()
    |> validate_inclusion(:source_origin, @source_origins)
  end
end
