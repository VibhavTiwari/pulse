defmodule Pulse.Repo.Migrations.AddIntelligenceCoreAskPulse do
  use Ecto.Migration

  def change do
    create table(:source_passages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :passage_index, :integer, null: false
      add :text, :text, null: false
      add :location_hint, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create constraint(:source_passages, :source_passages_text_not_blank,
             check: "length(trim(text)) > 0"
           )

    create index(:source_passages, [:workspace_id])
    create index(:source_passages, [:source_id])
    create index(:source_passages, [:workspace_id, :source_id])
    create unique_index(:source_passages, [:source_id, :passage_index])

    create table(:ask_threads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text

      timestamps(type: :utc_datetime)
    end

    create index(:ask_threads, [:workspace_id, :updated_at])

    create table(:ask_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :ask_thread_id, references(:ask_threads, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :text, null: false
      add :content, :text, null: false
      add :evidence_state, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:ask_messages, :ask_messages_role_valid,
             check: "role IN ('user', 'assistant')"
           )

    create constraint(:ask_messages, :ask_messages_content_not_blank,
             check: "length(trim(content)) > 0"
           )

    create constraint(:ask_messages, :ask_messages_evidence_state_valid,
             check:
               "evidence_state IS NULL OR evidence_state IN ('strong', 'weak', 'none', 'mixed')"
           )

    create constraint(:ask_messages, :ask_messages_assistant_has_evidence_state,
             check: "role != 'assistant' OR evidence_state IS NOT NULL"
           )

    create constraint(:ask_messages, :ask_messages_user_has_no_evidence_state,
             check: "role != 'user' OR evidence_state IS NULL"
           )

    create index(:ask_messages, [:workspace_id])
    create index(:ask_messages, [:ask_thread_id, :inserted_at])

    create table(:answer_citations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :ask_message_id, references(:ask_messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false

      add :source_passage_id,
          references(:source_passages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :evidence_text, :text
      add :location_hint, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:answer_citations, [:workspace_id])
    create index(:answer_citations, [:ask_message_id])
    create index(:answer_citations, [:source_id])
    create index(:answer_citations, [:source_passage_id])
  end
end
