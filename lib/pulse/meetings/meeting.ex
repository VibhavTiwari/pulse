defmodule Pulse.Meetings.Meeting do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  schema "meetings" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :meeting_date, :date
    field :description, :string
    field :attendees, {:array, :string}, default: []

    many_to_many :decisions, Pulse.Decisions.Decision, join_through: "meeting_decisions"
    many_to_many :commitments, Pulse.Commitments.Commitment, join_through: "meeting_commitments"
    many_to_many :risks, Pulse.Risks.Risk, join_through: "meeting_risks"

    timestamps()
  end

  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [:workspace_id, :title, :meeting_date, :description, :attendees])
    |> validate_trimmed_required([:workspace_id, :title, :meeting_date])
  end
end
