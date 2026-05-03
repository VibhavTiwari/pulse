defmodule Pulse.Intelligence.SourcePassage do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  schema "source_passages" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :source, Pulse.Sources.Source
    field :passage_index, :integer
    field :text, :string
    field :location_hint, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(passage, attrs) do
    passage
    |> cast(attrs, [:workspace_id, :source_id, :passage_index, :text, :location_hint, :metadata])
    |> validate_trimmed_required([:workspace_id, :source_id, :passage_index, :text])
  end
end
