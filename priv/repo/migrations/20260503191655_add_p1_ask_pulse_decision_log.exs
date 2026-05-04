defmodule Pulse.Repo.Migrations.AddP1AskPulseDecisionLog do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE answer_citations ALTER COLUMN source_id DROP NOT NULL",
      "ALTER TABLE answer_citations ALTER COLUMN source_id SET NOT NULL"
    )

    execute(
      "ALTER TABLE answer_citations ALTER COLUMN source_passage_id DROP NOT NULL",
      "ALTER TABLE answer_citations ALTER COLUMN source_passage_id SET NOT NULL"
    )

    alter table(:answer_citations) do
      add :supported_claim, :text
      add :citation_kind, :text, null: false, default: "source_passage"
      add :project_record_type, :text
      add :project_record_id, :binary_id
    end

    create constraint(:answer_citations, :answer_citations_citation_kind_valid,
             check: "citation_kind IN ('source_passage', 'project_record')"
           )

    create constraint(:answer_citations, :answer_citations_project_record_type_valid,
             check:
               "project_record_type IS NULL OR project_record_type IN ('decision', 'commitment')"
           )

    create index(:answer_citations, [:workspace_id, :citation_kind])
    create index(:answer_citations, [:project_record_type, :project_record_id])

    alter table(:decisions) do
      add :decision_state, :text, null: false, default: "accepted"

      add :superseded_by_decision_id,
          references(:decisions, type: :binary_id, on_delete: :nilify_all)

      add :reversal_reason, :text
      add :rationale, :text
      add :tradeoffs, :text
      add :alternatives_considered, :text
    end

    create constraint(:decisions, :decisions_decision_state_valid,
             check: "decision_state IN ('proposed', 'accepted', 'reversed', 'superseded')"
           )

    create constraint(:decisions, :decisions_no_self_supersession,
             check: "superseded_by_decision_id IS NULL OR superseded_by_decision_id <> id"
           )

    create index(:decisions, [:workspace_id, :decision_state])
    create index(:decisions, [:superseded_by_decision_id])
  end
end
