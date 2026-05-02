# Pulse Foundation

Local-first FastAPI foundation for Pulse: workspaces, SQLite persistence, source ingestion, chunk search, cited answers, seed data, and a static frontend.

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
