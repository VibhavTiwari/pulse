defmodule Pulse.Briefs.Brief do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @types ~w(daily)

  schema "briefs" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :brief_date, :date
    field :brief_type, :string, default: "daily"
    field :summary, :string
    field :sections, :map, default: %{}

    many_to_many :decisions, Pulse.Decisions.Decision, join_through: "brief_decisions"
    many_to_many :commitments, Pulse.Commitments.Commitment, join_through: "brief_commitments"
    many_to_many :risks, Pulse.Risks.Risk, join_through: "brief_risks"
    many_to_many :meetings, Pulse.Meetings.Meeting, join_through: "brief_meetings"

    timestamps()
  end

  def changeset(brief, attrs) do
    brief
    |> cast(attrs, [:workspace_id, :title, :brief_date, :brief_type, :summary, :sections])
    |> validate_trimmed_required([:workspace_id, :title, :brief_date, :brief_type, :summary])
    |> validate_inclusion(:brief_type, @types)
  end
end
