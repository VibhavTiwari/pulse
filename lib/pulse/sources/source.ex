defmodule Pulse.Sources.Source do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @source_types ~w(note document transcript meeting_note project_update other)
  @origins ~w(manual_upload manual_entry)
  @statuses ~w(pending ready failed)
  @classified_source_types ~w(meeting document update transcript plan)
  @classification_confidences ~w(high medium low manual)
  @classification_methods ~w(manual automatic metadata_only text_based)
  @quality_labels ~w(strong usable weak poor unknown)
  @quality_reasons ~w(thin stale unclear)

  def source_types, do: @source_types
  def origins, do: @origins
  def statuses, do: @statuses
  def classified_source_types, do: @classified_source_types
  def classification_confidences, do: @classification_confidences
  def classification_methods, do: @classification_methods
  def quality_labels, do: @quality_labels
  def quality_reasons, do: @quality_reasons

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
    field :classified_source_type, :string
    field :classification_confidence, :string
    field :classification_method, :string
    field :quality_label, :string, default: "unknown"
    field :quality_reasons, {:array, :string}, default: []
    field :quality_assessed_at, :utc_datetime

    has_many :duplicate_flags, Pulse.Sources.SourceDuplicateFlag

    has_many :matched_duplicate_flags, Pulse.Sources.SourceDuplicateFlag,
      foreign_key: :matched_source_id

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
      :deleted_at,
      :classified_source_type,
      :classification_confidence,
      :classification_method,
      :quality_label,
      :quality_reasons,
      :quality_assessed_at
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
    |> validate_enrichment_fields()
    |> validate_manual_entry_has_text()
    |> validate_ready_has_text()
  end

  def metadata_changeset(source, attrs) do
    source
    |> cast(attrs, [:title, :source_type, :source_date])
    |> validate_trimmed_required([:title, :source_type])
    |> validate_inclusion(:source_type, @source_types)
  end

  def enrichment_changeset(source, attrs) do
    source
    |> cast(attrs, [
      :classified_source_type,
      :classification_confidence,
      :classification_method,
      :quality_label,
      :quality_reasons,
      :quality_assessed_at
    ])
    |> validate_enrichment_fields()
  end

  def classification_changeset(source, attrs) do
    source
    |> cast(attrs, [:classified_source_type, :classification_confidence, :classification_method])
    |> validate_required([
      :classified_source_type,
      :classification_confidence,
      :classification_method
    ])
    |> validate_inclusion(:classified_source_type, @classified_source_types)
    |> validate_inclusion(:classification_confidence, @classification_confidences)
    |> validate_inclusion(:classification_method, @classification_methods)
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

  defp validate_enrichment_fields(changeset) do
    changeset
    |> validate_inclusion(:classified_source_type, @classified_source_types)
    |> validate_inclusion(:classification_confidence, @classification_confidences)
    |> validate_inclusion(:classification_method, @classification_methods)
    |> validate_inclusion(:quality_label, @quality_labels)
    |> validate_subset(:quality_reasons, @quality_reasons)
  end
end
