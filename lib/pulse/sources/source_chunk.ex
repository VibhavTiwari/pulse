defmodule Pulse.Sources.SourceChunk do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  schema "source_chunks" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :source, Pulse.Sources.Source
    field :chunk_index, :integer
    field :text, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:workspace_id, :source_id, :chunk_index, :text, :metadata])
    |> validate_trimmed_required([:workspace_id, :source_id, :chunk_index, :text])
  end
end
