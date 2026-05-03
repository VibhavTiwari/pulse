defmodule Pulse.Ask.AnswerCitation do
  use Pulse.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Pulse.ChangesetHelpers

  alias Pulse.Ask.Message
  alias Pulse.Intelligence.SourcePassage
  alias Pulse.Repo
  alias Pulse.Sources.Source

  schema "answer_citations" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :message, Message, foreign_key: :ask_message_id
    belongs_to :source, Source
    belongs_to :source_passage, SourcePassage
    field :evidence_text, :string
    field :location_hint, :string

    timestamps(updated_at: false)
  end

  def changeset(citation, attrs) do
    citation
    |> cast(attrs, [
      :workspace_id,
      :ask_message_id,
      :source_id,
      :source_passage_id,
      :evidence_text,
      :location_hint
    ])
    |> validate_trimmed_required([:workspace_id, :ask_message_id, :source_id, :source_passage_id])
    |> validate_workspace_consistency()
  end

  defp validate_workspace_consistency(changeset) do
    workspace_id = get_field(changeset, :workspace_id)
    message_id = get_field(changeset, :ask_message_id)
    source_id = get_field(changeset, :source_id)
    passage_id = get_field(changeset, :source_passage_id)

    if Enum.any?([workspace_id, message_id, source_id, passage_id], &is_nil/1) do
      changeset
    else
      changeset
      |> validate_message_workspace(workspace_id, message_id)
      |> validate_source_workspace(workspace_id, source_id)
      |> validate_passage_workspace(workspace_id, source_id, passage_id)
    end
  end

  defp validate_message_workspace(changeset, workspace_id, message_id) do
    valid? =
      Repo.exists?(
        from m in Message,
          where: m.id == ^message_id and m.workspace_id == ^workspace_id and m.role == "assistant"
      )

    if valid?, do: changeset, else: add_error(changeset, :ask_message_id, "is invalid")
  end

  defp validate_source_workspace(changeset, workspace_id, source_id) do
    valid? =
      Repo.exists?(
        from s in Source,
          where: s.id == ^source_id and s.workspace_id == ^workspace_id
      )

    if valid?, do: changeset, else: add_error(changeset, :source_id, "is invalid")
  end

  defp validate_passage_workspace(changeset, workspace_id, source_id, passage_id) do
    valid? =
      Repo.exists?(
        from p in SourcePassage,
          where:
            p.id == ^passage_id and p.source_id == ^source_id and p.workspace_id == ^workspace_id
      )

    if valid?, do: changeset, else: add_error(changeset, :source_passage_id, "is invalid")
  end
end
