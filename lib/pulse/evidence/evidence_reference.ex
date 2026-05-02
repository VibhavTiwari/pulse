defmodule Pulse.Evidence.EvidenceReference do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @target_types ~w(decision commitment risk meeting brief)

  schema "evidence_references" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :source, Pulse.Sources.Source
    field :target_entity_type, :string
    field :target_entity_id, :binary_id
    field :evidence_text, :string
    field :location_hint, :string

    timestamps(updated_at: false)
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :workspace_id,
      :source_id,
      :target_entity_type,
      :target_entity_id,
      :evidence_text,
      :location_hint
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :source_id,
      :target_entity_type,
      :target_entity_id
    ])
    |> validate_inclusion(:target_entity_type, @target_types)
  end
end
