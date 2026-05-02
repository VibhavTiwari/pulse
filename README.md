# Pulse

Pulse is now a Phoenix/Ecto/PostgreSQL application for the P0 executive/project intelligence data model.

## Stack

- Elixir on the Erlang VM
- Phoenix serving the frontend and JSON APIs
- Ecto with PostgreSQL as the system of record
- Static Pulse UI served by Phoenix from `priv/static`

## Run Locally

PowerShell in this environment needs Erlang, Elixir, and PostgreSQL added to the command PATH:

```powershell
$env:Path='C:\Program Files\Erlang OTP\bin;C:\Program Files\Elixir\bin;C:\Program Files\PostgreSQL\18\bin;' + $env:Path
mix setup
mix phx.server
```

Open:

- App: http://127.0.0.1:4000/

The default development database config is in `config/dev.exs` and uses:

```text
username: postgres
password: postgres
database: pulse_dev
```

## P0 Data Model

Implemented:

- Workspaces
- Sources and source chunks
- Evidence references
- Decisions with `suggested`, `accepted`, `rejected`
- Commitments with due-date consistency
- Risks/blockers
- Meetings linked to decisions, commitments, and risks
- Briefs with structured sections and linked records

User-facing project truth endpoints default to accepted records.

## Verification

```powershell
mix compile --warnings-as-errors
mix test
mix ecto.setup
```
