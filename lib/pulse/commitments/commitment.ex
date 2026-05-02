defmodule Pulse.Commitments.Commitment do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @statuses ~w(open done overdue blocked)

  schema "commitments" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :description, :string
    field :owner, :string
    field :due_date, :date
    field :due_date_known, :boolean, default: false
    field :status, :string, default: "open"
    field :record_state, :string, default: "accepted"
    field :source_origin, :string

    timestamps()
  end

  def changeset(commitment, attrs) do
    commitment
    |> cast(attrs, [
      :workspace_id,
      :title,
      :description,
      :owner,
      :due_date,
      :due_date_known,
      :status,
      :record_state,
      :source_origin
    ])
    |> validate_trimmed_required([:workspace_id, :title, :owner, :status, :record_state])
    |> validate_inclusion(:status, @statuses)
    |> validate_record_state()
    |> validate_due_date_consistency()
  end

  defp validate_due_date_consistency(changeset) do
    if get_field(changeset, :due_date_known) && is_nil(get_field(changeset, :due_date)) do
      add_error(changeset, :due_date, "is required when due_date_known is true")
    else
      changeset
    end
  end
end
