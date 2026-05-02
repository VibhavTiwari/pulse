defmodule Pulse.Sources.Source do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @statuses ~w(pending ready failed)

  schema "sources" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :source_type, :string
    field :origin, :string
    field :source_date, :date
    field :text_content, :string
    field :metadata, :map, default: %{}
    field :processing_status, :string, default: "pending"
    field :file_path, :string
    field :original_filename, :string
    field :mime_type, :string
    field :content_hash, :string
    field :error_message, :string
    field :deleted_at, :utc_datetime

    timestamps()
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :workspace_id,
      :title,
      :source_type,
      :origin,
      :source_date,
      :text_content,
      :metadata,
      :processing_status,
      :file_path,
      :original_filename,
      :mime_type,
      :content_hash,
      :error_message,
      :deleted_at
    ])
    |> validate_trimmed_required([
      :workspace_id,
      :title,
      :source_type,
      :origin,
      :processing_status
    ])
    |> validate_inclusion(:processing_status, @statuses)
    |> validate_ready_has_text()
  end

  defp validate_ready_has_text(changeset) do
    status = get_field(changeset, :processing_status)
    text = get_field(changeset, :text_content)

    if status == "ready" and (is_nil(text) or String.trim(text) == "") do
      add_error(changeset, :text_content, "is required when source is ready")
    else
      changeset
    end
  end
end
