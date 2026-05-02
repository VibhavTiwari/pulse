from __future__ import annotations

import json
from pathlib import Path

from pulse import repository
from pulse.db import get_db, init_db
from pulse.ids import make_id
from pulse.ingestion import chunk_text, content_hash
from pulse.settings import settings
from pulse.time import utc_now


DEMO_SOURCES = [
    (
        "Launch Notes.md",
        "markdown",
        """# Launch Notes

The launch should prioritize a focused private beta before any public announcement. The team decided that the first release will target project leads who already collect decisions and commitments across Slack, meetings, and documents.

The launch plan should emphasize trust: every AI answer must include citations, and uncited answers should be treated as unsupported. The first public message should avoid broad automation claims until the evidence engine is reliable.
""",
    ),
    (
        "Evidence Engine Brief.md",
        "markdown",
        """# Evidence Engine Brief

Pulse should use local workspace data as the source of truth. Source ingestion must preserve files on disk, store chunks in SQLite, and return citations that point to source titles and chunk locations.

The retrieval layer can begin with keyword search as long as the chunk table is vector-ready. The team agreed to keep extraction deterministic for P0 so demos work without external credentials.
""",
    ),
    (
        "Meeting Followups.txt",
        "text",
        """Rina owns the beta invite list and will prepare the first 20 customer contacts by 2026-05-10.

Dev owns the local source uploader and will make failed ingestion errors readable by 2026-05-08.

Maya will draft the daily brief format and include decisions, open commitments, and meeting prep by 2026-05-12.
""",
    ),
    (
        "Workspace Architecture.md",
        "markdown",
        """# Workspace Architecture

Each Pulse workspace should create a .pulse folder with a SQLite database, sources, indexes, exports, and runs directories. The database stores workspaces, sources, source chunks, answers, citations, decisions, commitments, briefs, meetings, and runs.

Workspace health should report whether the local folder and database are present and how many indexed sources, chunks, and answers exist.
""",
    ),
]


def _clear_demo(conn) -> None:
    for table in [
        "citations",
        "ai_answers",
        "runs",
        "meetings",
        "briefs",
        "commitments",
        "decisions",
        "source_chunks",
        "sources",
        "workspaces",
    ]:
        conn.execute(f"DELETE FROM {table}")


def _insert_demo_sources(conn, workspace: dict) -> list[dict]:
    source_dir = Path(workspace["root_path"]) / ".pulse" / "sources"
    source_dir.mkdir(parents=True, exist_ok=True)
    inserted = []
    now = utc_now()
    for filename, source_type, body in DEMO_SOURCES:
        path = source_dir / filename
        path.write_text(body, encoding="utf-8")
        digest = content_hash(body.encode("utf-8"))
        source = repository.insert_source(
            conn,
            workspace_id=workspace["id"],
            title=Path(filename).stem,
            source_type=source_type,
            file_path=str(path),
            original_filename=filename,
            mime_type="text/markdown" if filename.endswith(".md") else "text/plain",
            content_hash=digest,
            status="indexed",
        )
        repository.replace_chunks(conn, source["id"], workspace["id"], chunk_text(body))
        conn.execute("UPDATE sources SET created_at = ?, updated_at = ? WHERE id = ?", (now, now, source["id"]))
        inserted.append(repository.get_source(conn, source["id"], include_chunks=True))
    return inserted


def _insert_seeded_views(conn, workspace_id: str, sources: list[dict]) -> None:
    now = utc_now()
    decisions = [
        ("Private beta first", "Launch with a narrow private beta before a public announcement.", "accepted", "The launch notes favor learning from project leads before broad claims."),
        ("Citations required", "AI answers must include source citations to be considered supported.", "accepted", "Trust is the central product promise for the evidence engine."),
        ("Keyword retrieval for P0", "Start with deterministic keyword retrieval while keeping the schema vector-ready.", "accepted", "This keeps the demo local and avoids external credentials."),
    ]
    for title, summary, status, rationale in decisions:
        conn.execute(
            "INSERT INTO decisions(id, workspace_id, title, summary, status, rationale, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (make_id("dec"), workspace_id, title, summary, status, rationale, now, now),
        )

    source_id = sources[2]["id"]
    commitments = [
        ("Rina", "Prepare the first 20 beta customer contacts.", "2026-05-10", "open", source_id),
        ("Dev", "Make failed ingestion errors readable in the Sources view.", "2026-05-08", "open", source_id),
        ("Maya", "Draft the daily brief format with decisions and commitments.", "2026-05-12", "open", source_id),
        ("Dev", "Persist workspace health counts in API responses.", "2026-05-06", "done", None),
        ("Rina", "Review launch messaging for unsupported automation claims.", "2026-05-14", "open", None),
    ]
    for owner, description, due_date, status, commitment_source_id in commitments:
        conn.execute(
            "INSERT INTO commitments(id, workspace_id, owner, description, due_date, status, source_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (make_id("com"), workspace_id, owner, description, due_date, status, commitment_source_id, now, now),
        )

    conn.execute(
        "INSERT INTO briefs(id, workspace_id, brief_date, title, summary, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (
            make_id("brief"),
            workspace_id,
            "2026-05-02",
            "Daily Brief",
            "Focus today on proving the local evidence loop: create the workspace, ingest sources, retrieve cited chunks, and show saved decisions and commitments.",
            now,
        ),
    )
    conn.execute(
        "INSERT INTO meetings(id, workspace_id, title, meeting_date, attendees_json, agenda, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (
            make_id("mtg"),
            workspace_id,
            "Pulse P0 Planning Review",
            "2026-05-03T10:00:00",
            json.dumps(["Rina", "Dev", "Maya"]),
            "Confirm private beta scope, review cited Ask AI behavior, and assign remaining source ingestion follow-ups.",
            now,
            now,
        ),
    )


def _insert_demo_answers(conn, workspace_id: str) -> None:
    questions = [
        "What decisions have we made about the launch plan?",
        "How should Pulse handle citations?",
        "Who owns the current commitments?",
    ]
    from pulse.ai import ask_workspace

    for question in questions:
        ask_workspace(conn, workspace_id, question)


def reset_demo_data() -> dict:
    init_db()
    with get_db() as conn:
        _clear_demo(conn)
        workspace = repository.create_workspace(conn, "Pulse Demo Workspace", str(settings.project_root))
        sources = _insert_demo_sources(conn, workspace)
        _insert_seeded_views(conn, workspace["id"], sources)
        _insert_demo_answers(conn, workspace["id"])
        return repository.get_workspace(conn, workspace["id"]) or workspace


def main() -> None:
    workspace = reset_demo_data()
    print(f"Seeded demo workspace: {workspace['name']} ({workspace['id']})")
    print(f"Database: {workspace['database_path']}")


if __name__ == "__main__":
    main()
