defmodule Pulse.Risks.Risk do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @severities ~w(low medium high critical)
  @statuses ~w(open mitigated resolved)
  @source_origins ~w(manual extracted)

  schema "risks" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :description, :string
    field :severity, :string
    field :owner, :string
    field :status, :string, default: "open"
    field :mitigation, :string
    field :record_state, :string, default: "accepted"
    field :source_origin, :string

    timestamps()
  end

  def changeset(risk, attrs) do
    risk
    |> cast(attrs, [
      :workspace_id,
      :title,
      :description,
      :severity,
      :owner,
      :status,
      :mitigation,
      :record_state,
      :source_origin
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :title,
      :description,
      :severity,
      :owner,
      :status,
      :record_state
    ])
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:status, @statuses)
    |> validate_record_state()
    |> validate_inclusion(:source_origin, @source_origins)
  end
end
