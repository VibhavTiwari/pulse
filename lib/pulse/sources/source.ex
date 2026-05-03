defmodule Pulse.Sources.Source do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @source_types ~w(note document transcript meeting_note project_update other)
  @origins ~w(manual_upload manual_entry)
  @statuses ~w(pending ready failed)

  def source_types, do: @source_types
  def origins, do: @origins
  def statuses, do: @statuses

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
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:processing_status, @statuses)
    |> validate_manual_entry_has_text()
    |> validate_ready_has_text()
  end

  def metadata_changeset(source, attrs) do
    source
    |> cast(attrs, [:title, :source_type, :source_date])
    |> validate_trimmed_required([:title, :source_type])
    |> validate_inclusion(:source_type, @source_types)
  end

  def text_changeset(source, attrs) do
    source
    |> cast(attrs, [:text_content, :processing_status, :error_message])
    |> validate_trimmed_required([:processing_status])
    |> validate_inclusion(:processing_status, @statuses)
    |> validate_manual_entry_has_text()
    |> validate_ready_has_text()
  end

  def status_changeset(source, attrs) do
    source
    |> cast(attrs, [:processing_status, :error_message, :text_content])
    |> validate_trimmed_required([:processing_status])
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

  defp validate_manual_entry_has_text(changeset) do
    origin = get_field(changeset, :origin)
    text = get_field(changeset, :text_content)

    if origin == "manual_entry" and (is_nil(text) or String.trim(text) == "") do
      add_error(changeset, :text_content, "is required for manual entry sources")
    else
      changeset
    end
  end
end
