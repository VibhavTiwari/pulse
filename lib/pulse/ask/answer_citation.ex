defmodule Pulse.Ask.AnswerCitation do
  use Pulse.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Pulse.ChangesetHelpers

  alias Pulse.Commitments.Commitment
  alias Pulse.Decisions.Decision
  alias Pulse.Ask.Message
  alias Pulse.Intelligence.SourcePassage
  alias Pulse.Repo
  alias Pulse.Sources.Source

  @citation_kinds ~w(source_passage project_record)
  @project_record_types ~w(decision commitment)

  schema "answer_citations" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :message, Message, foreign_key: :ask_message_id
    belongs_to :source, Source
    belongs_to :source_passage, SourcePassage
    field :evidence_text, :string
    field :location_hint, :string
    field :supported_claim, :string
    field :citation_kind, :string, default: "source_passage"
    field :project_record_type, :string
    field :project_record_id, Ecto.UUID

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
      :location_hint,
      :supported_claim,
      :citation_kind,
      :project_record_type,
      :project_record_id
    ])
    |> validate_trimmed_required([:workspace_id, :ask_message_id, :citation_kind])
    |> validate_inclusion(:citation_kind, @citation_kinds)
    |> validate_inclusion(:project_record_type, @project_record_types)
    |> validate_required_for_kind()
    |> validate_workspace_consistency()
  end

  defp validate_required_for_kind(changeset) do
    case get_field(changeset, :citation_kind) do
      "source_passage" ->
        validate_trimmed_required(changeset, [:source_id, :source_passage_id])

      "project_record" ->
        validate_trimmed_required(changeset, [:project_record_type, :project_record_id])

      _ ->
        changeset
    end
  end

  defp validate_workspace_consistency(changeset) do
    workspace_id = get_field(changeset, :workspace_id)
    message_id = get_field(changeset, :ask_message_id)
    source_id = get_field(changeset, :source_id)
    passage_id = get_field(changeset, :source_passage_id)
    project_record_type = get_field(changeset, :project_record_type)
    project_record_id = get_field(changeset, :project_record_id)

    if is_nil(workspace_id) or is_nil(message_id) do
      changeset
    else
      changeset
      |> validate_message_workspace(workspace_id, message_id)
      |> validate_kind_workspace(
        workspace_id,
        source_id,
        passage_id,
        project_record_type,
        project_record_id
      )
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

  defp validate_kind_workspace(
         changeset,
         workspace_id,
         source_id,
         passage_id,
         _project_record_type,
         _project_record_id
       )
       when is_binary(source_id) and is_binary(passage_id) do
    changeset
    |> validate_source_workspace(workspace_id, source_id)
    |> validate_passage_workspace(workspace_id, source_id, passage_id)
  end

  defp validate_kind_workspace(
         changeset,
         workspace_id,
         _source_id,
         _passage_id,
         project_record_type,
         project_record_id
       )
       when is_binary(project_record_type) and is_binary(project_record_id) do
    validate_project_record_workspace(
      changeset,
      workspace_id,
      project_record_type,
      project_record_id
    )
  end

  defp validate_kind_workspace(changeset, _workspace_id, _source_id, _passage_id, _type, _id),
    do: changeset

  defp validate_source_workspace(changeset, workspace_id, source_id) do
    valid? =
      Repo.exists?(
        from s in Source,
          where:
            s.id == ^source_id and s.workspace_id == ^workspace_id and
              s.processing_status == "ready"
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

  defp validate_project_record_workspace(changeset, workspace_id, "decision", project_record_id) do
    valid? =
      Repo.exists?(
        from d in Decision,
          where:
            d.id == ^project_record_id and d.workspace_id == ^workspace_id and
              d.record_state == "accepted"
      )

    if valid?, do: changeset, else: add_error(changeset, :project_record_id, "is invalid")
  end

  defp validate_project_record_workspace(changeset, workspace_id, "commitment", project_record_id) do
    valid? =
      Repo.exists?(
        from c in Commitment,
          where:
            c.id == ^project_record_id and c.workspace_id == ^workspace_id and
              c.record_state == "accepted"
      )

    if valid?, do: changeset, else: add_error(changeset, :project_record_id, "is invalid")
  end

  defp validate_project_record_workspace(changeset, _workspace_id, _type, _project_record_id),
    do: changeset
end
