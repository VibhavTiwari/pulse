defmodule Pulse.Repo.Migrations.AddP1SourceLibraryEnrichment do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :classified_source_type, :text
      add :classification_confidence, :text
      add :classification_method, :text
      add :quality_label, :text, null: false, default: "unknown"
      add :quality_reasons, {:array, :text}, null: false, default: []
      add :quality_assessed_at, :utc_datetime
    end

    create constraint(:sources, :sources_classified_source_type_valid,
             check:
               "classified_source_type IS NULL OR classified_source_type IN ('meeting', 'document', 'update', 'transcript', 'plan')"
           )

    create constraint(:sources, :sources_classification_confidence_valid,
             check:
               "classification_confidence IS NULL OR classification_confidence IN ('high', 'medium', 'low', 'manual')"
           )

    create constraint(:sources, :sources_classification_method_valid,
             check:
               "classification_method IS NULL OR classification_method IN ('manual', 'automatic', 'metadata_only', 'text_based')"
           )

    create constraint(:sources, :sources_quality_label_valid,
             check: "quality_label IN ('strong', 'usable', 'weak', 'poor', 'unknown')"
           )

    create constraint(:sources, :sources_quality_reasons_valid,
             check: "quality_reasons <@ ARRAY['thin', 'stale', 'unclear']::text[]"
           )

    create index(:sources, [:workspace_id, :classified_source_type])
    create index(:sources, [:workspace_id, :quality_label])

    create table(:source_duplicate_flags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false

      add :matched_source_id, references(:sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :duplicate_type, :text, null: false
      add :confidence, :text, null: false
      add :reason, :text, null: false
      add :resolution_state, :text, null: false, default: "unresolved"

      timestamps(type: :utc_datetime)
    end

    create constraint(:source_duplicate_flags, :source_duplicate_flags_type_valid,
             check:
               "duplicate_type IN ('exact_duplicate', 'near_duplicate', 'possible_duplicate')"
           )

    create constraint(:source_duplicate_flags, :source_duplicate_flags_confidence_valid,
             check: "confidence IN ('high', 'medium', 'low')"
           )

    create constraint(:source_duplicate_flags, :source_duplicate_flags_resolution_valid,
             check: "resolution_state IN ('unresolved', 'confirmed_duplicate', 'dismissed')"
           )

    create constraint(:source_duplicate_flags, :source_duplicate_flags_no_self_duplicate,
             check: "source_id <> matched_source_id"
           )

    create unique_index(:source_duplicate_flags, [:source_id, :matched_source_id])
    create index(:source_duplicate_flags, [:workspace_id, :resolution_state])
    create index(:source_duplicate_flags, [:matched_source_id])
  end
end
