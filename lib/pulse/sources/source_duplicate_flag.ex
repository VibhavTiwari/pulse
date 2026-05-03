defmodule Pulse.Sources.SourceDuplicateFlag do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @duplicate_types ~w(exact_duplicate near_duplicate possible_duplicate)
  @confidences ~w(high medium low)
  @resolution_states ~w(unresolved confirmed_duplicate dismissed)

  def duplicate_types, do: @duplicate_types
  def confidences, do: @confidences
  def resolution_states, do: @resolution_states

  schema "source_duplicate_flags" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :source, Pulse.Sources.Source
    belongs_to :matched_source, Pulse.Sources.Source

    field :duplicate_type, :string
    field :confidence, :string
    field :reason, :string
    field :resolution_state, :string, default: "unresolved"

    timestamps()
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [
      :workspace_id,
      :source_id,
      :matched_source_id,
      :duplicate_type,
      :confidence,
      :reason,
      :resolution_state
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :source_id,
      :matched_source_id,
      :duplicate_type,
      :confidence,
      :reason,
      :resolution_state
    ])
    |> validate_inclusion(:duplicate_type, @duplicate_types)
    |> validate_inclusion(:confidence, @confidences)
    |> validate_inclusion(:resolution_state, @resolution_states)
    |> validate_not_self_duplicate()
    |> unique_constraint([:source_id, :matched_source_id])
  end

  def resolution_changeset(flag, attrs) do
    flag
    |> cast(attrs, [:resolution_state])
    |> validate_trimmed_required([:resolution_state])
    |> validate_inclusion(:resolution_state, @resolution_states)
  end

  defp validate_not_self_duplicate(changeset) do
    source_id = get_field(changeset, :source_id)
    matched_source_id = get_field(changeset, :matched_source_id)

    if source_id && matched_source_id && source_id == matched_source_id do
      add_error(changeset, :matched_source_id, "cannot match the same source")
    else
      changeset
    end
  end
end
