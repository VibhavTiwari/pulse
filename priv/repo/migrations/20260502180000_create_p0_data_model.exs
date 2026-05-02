defmodule Pulse.Repo.Migrations.CreateP0DataModel do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :root_path, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:workspaces, :workspaces_name_not_blank, check: "length(trim(name)) > 0")

    create constraint(:workspaces, :workspaces_root_path_not_blank,
             check: "length(trim(root_path)) > 0"
           )

    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :source_type, :text, null: false
      add :origin, :text, null: false
      add :source_date, :date
      add :text_content, :text
      add :metadata, :map, null: false, default: %{}
      add :processing_status, :text, null: false, default: "pending"
      add :file_path, :text
      add :original_filename, :text
      add :mime_type, :text
      add :content_hash, :text
      add :error_message, :text
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:sources, :sources_title_not_blank, check: "length(trim(title)) > 0")

    create constraint(:sources, :sources_source_type_not_blank,
             check: "length(trim(source_type)) > 0"
           )

    create constraint(:sources, :sources_origin_not_blank, check: "length(trim(origin)) > 0")

    create constraint(:sources, :sources_processing_status_valid,
             check: "processing_status IN ('pending', 'ready', 'failed')"
           )

    create constraint(:sources, :sources_ready_has_text,
             check: "processing_status != 'ready' OR text_content IS NOT NULL"
           )

    create index(:sources, [:workspace_id])
    create index(:sources, [:processing_status])
    create index(:sources, [:source_date])

    create table(:source_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :chunk_index, :integer, null: false
      add :text, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:source_chunks, :source_chunks_text_not_blank,
             check: "length(trim(text)) > 0"
           )

    create index(:source_chunks, [:workspace_id])
    create unique_index(:source_chunks, [:source_id, :chunk_index])

    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :context, :text, null: false
      add :decision_date, :date, null: false
      add :owner, :text, null: false
      add :status, :text, null: false, default: "active"
      add :record_state, :text, null: false, default: "accepted"
      add :source_origin, :text

      timestamps(type: :utc_datetime)
    end

    create constraint(:decisions, :decisions_title_not_blank, check: "length(trim(title)) > 0")

    create constraint(:decisions, :decisions_context_not_blank,
             check: "length(trim(context)) > 0"
           )

    create constraint(:decisions, :decisions_owner_not_blank, check: "length(trim(owner)) > 0")

    create constraint(:decisions, :decisions_status_valid,
             check: "status IN ('active', 'inactive')"
           )

    create constraint(:decisions, :decisions_record_state_valid,
             check: "record_state IN ('suggested', 'accepted', 'rejected')"
           )

    create index(:decisions, [:workspace_id])
    create index(:decisions, [:record_state])
    create index(:decisions, [:decision_date])
    create index(:decisions, [:status])

    create table(:commitments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :description, :text
      add :owner, :text, null: false
      add :due_date, :date
      add :due_date_known, :boolean, null: false, default: false
      add :status, :text, null: false, default: "open"
      add :record_state, :text, null: false, default: "accepted"
      add :source_origin, :text

      timestamps(type: :utc_datetime)
    end

    create constraint(:commitments, :commitments_title_not_blank,
             check: "length(trim(title)) > 0"
           )

    create constraint(:commitments, :commitments_owner_not_blank,
             check: "length(trim(owner)) > 0"
           )

    create constraint(:commitments, :commitments_status_valid,
             check: "status IN ('open', 'done', 'overdue', 'blocked')"
           )

    create constraint(:commitments, :commitments_record_state_valid,
             check: "record_state IN ('suggested', 'accepted', 'rejected')"
           )

    create constraint(:commitments, :commitments_due_date_consistent,
             check: "due_date_known = false OR due_date IS NOT NULL"
           )

    create index(:commitments, [:workspace_id])
    create index(:commitments, [:record_state])
    create index(:commitments, [:status])
    create index(:commitments, [:due_date])
    create index(:commitments, [:owner])

    create table(:risks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :description, :text, null: false
      add :severity, :text, null: false
      add :owner, :text, null: false
      add :status, :text, null: false, default: "open"
      add :mitigation, :text
      add :record_state, :text, null: false, default: "accepted"
      add :source_origin, :text

      timestamps(type: :utc_datetime)
    end

    create constraint(:risks, :risks_title_not_blank, check: "length(trim(title)) > 0")

    create constraint(:risks, :risks_description_not_blank,
             check: "length(trim(description)) > 0"
           )

    create constraint(:risks, :risks_owner_not_blank, check: "length(trim(owner)) > 0")

    create constraint(:risks, :risks_severity_valid,
             check: "severity IN ('low', 'medium', 'high', 'critical')"
           )

    create constraint(:risks, :risks_status_valid,
             check: "status IN ('open', 'mitigated', 'resolved')"
           )

    create constraint(:risks, :risks_record_state_valid,
             check: "record_state IN ('suggested', 'accepted', 'rejected')"
           )

    create index(:risks, [:workspace_id])
    create index(:risks, [:record_state])
    create index(:risks, [:severity])
    create index(:risks, [:status])
    create index(:risks, [:owner])

    create table(:meetings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :meeting_date, :date, null: false
      add :description, :text
      add :attendees, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create constraint(:meetings, :meetings_title_not_blank, check: "length(trim(title)) > 0")
    create index(:meetings, [:workspace_id])
    create index(:meetings, [:meeting_date])

    create table(:briefs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :brief_date, :date, null: false
      add :brief_type, :text, null: false, default: "daily"
      add :summary, :text, null: false
      add :sections, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create constraint(:briefs, :briefs_title_not_blank, check: "length(trim(title)) > 0")
    create constraint(:briefs, :briefs_summary_not_blank, check: "length(trim(summary)) > 0")
    create constraint(:briefs, :briefs_brief_type_valid, check: "brief_type IN ('daily')")
    create index(:briefs, [:workspace_id])
    create index(:briefs, [:brief_date])
    create index(:briefs, [:brief_type])

    create table(:evidence_references, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :target_entity_type, :text, null: false
      add :target_entity_id, :binary_id, null: false
      add :evidence_text, :text
      add :location_hint, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:evidence_references, :evidence_target_type_valid,
             check: "target_entity_type IN ('decision', 'commitment', 'risk', 'meeting', 'brief')"
           )

    create index(:evidence_references, [:workspace_id])
    create index(:evidence_references, [:source_id])
    create index(:evidence_references, [:target_entity_type, :target_entity_id])

    create_join(:meeting_decisions, :meeting_id, :meetings, :decision_id, :decisions)
    create_join(:meeting_commitments, :meeting_id, :meetings, :commitment_id, :commitments)
    create_join(:meeting_risks, :meeting_id, :meetings, :risk_id, :risks)
    create_join(:brief_decisions, :brief_id, :briefs, :decision_id, :decisions)
    create_join(:brief_commitments, :brief_id, :briefs, :commitment_id, :commitments)
    create_join(:brief_risks, :brief_id, :briefs, :risk_id, :risks)
    create_join(:brief_meetings, :brief_id, :briefs, :meeting_id, :meetings)
  end

  defp create_join(table, left_key, left_table, right_key, right_table) do
    create table(table, primary_key: false) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add left_key, references(left_table, type: :binary_id, on_delete: :delete_all), null: false

      add right_key, references(right_table, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(table, [left_key, right_key])
    create index(table, [:workspace_id])
  end
end
