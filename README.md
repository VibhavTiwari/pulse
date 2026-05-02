# Pulse Foundation

Local-first FastAPI foundation for Pulse: workspaces, SQLite persistence, source ingestion, chunk search, cited answers, seed data, and a static frontend.

The current runnable implementation is Python/FastAPI + SQLite because this workspace does not include Elixir or PostgreSQL tooling. The P0 data model is implemented with the same product boundaries the Elixir/PostgreSQL backend should preserve later: sources, evidence references, decisions, commitments, risks, meetings, briefs, review states, and relationship tables.

## Run

```powershell
python -m pulse.seed
uvicorn apps.api.app.main:app --reload
```

Open:

- App: http://127.0.0.1:8000/
- API docs: http://127.0.0.1:8000/docs

## Useful Commands

```powershell
python -m pulse.seed          # reset and load demo data
pytest                        # run smoke tests
```

## P0 Data Model

Implemented records:

- Sources with `pending`, `ready`, and `failed` processing states
- Evidence references from sources to decisions, commitments, risks, meetings, and briefs
- Decisions with `suggested`, `accepted`, and `rejected` review states
- Commitments with due-date consistency and `open`, `done`, `overdue`, `blocked` statuses
- Risks with severity and status
- Meetings linked to decisions, commitments, and risks
- Briefs with structured sections and links to project records

User-facing project truth endpoints default to `accepted` records.

By default Pulse stores local data under:

```text
.pulse/
  pulse.db
  sources/
  indexes/
  exports/
  runs/
```

Set `PULSE_HOME` to use another local workspace root.
