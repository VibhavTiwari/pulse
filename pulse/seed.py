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
        "brief_meetings",
        "brief_risks",
        "brief_commitments",
        "brief_decisions",
        "meeting_risks",
        "meeting_commitments",
        "meeting_decisions",
        "evidence_references",
        "runs",
        "meetings",
        "briefs",
        "risks",
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
            status="ready",
            origin="manual_upload",
            text_content=body,
            metadata={"filename": filename},
            processing_status="ready",
        )
        repository.replace_chunks(conn, source["id"], workspace["id"], chunk_text(body))
        conn.execute("UPDATE sources SET created_at = ?, updated_at = ? WHERE id = ?", (now, now, source["id"]))
        inserted.append(repository.get_source(conn, source["id"], include_chunks=True))
    return inserted


def _insert_seeded_views(conn, workspace_id: str, sources: list[dict]) -> None:
    launch_source, evidence_source, followup_source, architecture_source = sources
    private_beta = repository.create_entity(
        conn,
        "decision",
        workspace_id,
        {
            "title": "Private beta first",
            "context": "Launch with a narrow private beta before a public announcement.",
            "decision_date": "2026-05-02",
            "owner": "Rina",
            "status": "active",
            "record_state": "accepted",
            "source_origin": "extracted",
        },
        manual=False,
    )
    citations_required = repository.create_entity(
        conn,
        "decision",
        workspace_id,
        {
            "title": "Citations required",
            "context": "AI answers must include source citations to be considered supported.",
            "decision_date": "2026-05-02",
            "owner": "Dev",
            "status": "active",
            "record_state": "accepted",
            "source_origin": "extracted",
        },
        manual=False,
    )
    suggested_decision = repository.create_entity(
        conn,
        "decision",
        workspace_id,
        {
            "title": "Keyword retrieval for P0",
            "context": "Start with deterministic keyword retrieval while keeping the schema vector-ready.",
            "decision_date": "2026-05-02",
            "owner": "Dev",
            "status": "active",
            "record_state": "suggested",
            "source_origin": "extracted",
        },
        manual=False,
    )
    for decision, source, text in [
        (private_beta, launch_source, "The launch should prioritize a focused private beta before any public announcement."),
        (citations_required, launch_source, "Every AI answer must include citations, and uncited answers should be treated as unsupported."),
        (suggested_decision, evidence_source, "The retrieval layer can begin with keyword search as long as the chunk table is vector-ready."),
    ]:
        repository.create_evidence_reference(
            conn,
            workspace_id=workspace_id,
            source_id=source["id"],
            target_entity_type="decision",
            target_entity_id=decision["id"],
            evidence_text=text,
            location_hint="seed excerpt",
        )

    commitments = []
    for owner, title, due_date, status, source_origin in [
        ("Rina", "Prepare first 20 beta customer contacts", "2026-05-10", "open", "extracted"),
        ("Dev", "Make failed ingestion errors readable", "2026-05-08", "open", "extracted"),
        ("Maya", "Draft daily brief format", "2026-05-12", "open", "extracted"),
        ("Dev", "Persist workspace health counts", "2026-05-06", "done", "manual"),
        ("Rina", "Review unsupported launch messaging claims", "2026-05-14", "open", "manual"),
    ]:
        commitment = repository.create_entity(
            conn,
            "commitment",
            workspace_id,
            {
                "title": title,
                "description": title,
                "owner": owner,
                "due_date": due_date,
                "due_date_known": True,
                "status": status,
                "record_state": "accepted",
                "source_origin": source_origin,
            },
            manual=source_origin == "manual",
        )
        commitments.append(commitment)
    for commitment in commitments[:3]:
        repository.create_evidence_reference(
            conn,
            workspace_id=workspace_id,
            source_id=followup_source["id"],
            target_entity_type="commitment",
            target_entity_id=commitment["id"],
            evidence_text=commitment["description"],
            location_hint="follow-up list",
        )

    risks = []
    for title, description, severity, owner, status, mitigation, source in [
        (
            "Unsupported automation claims",
            "Public messaging could overstate automation before the evidence engine is reliable.",
            "high",
            "Rina",
            "open",
            "Keep launch copy grounded in source-backed outputs.",
            launch_source,
        ),
        (
            "External credential dependency",
            "The demo must work without external model or integration credentials.",
            "medium",
            "Dev",
            "mitigated",
            "Use deterministic local retrieval for P0.",
            evidence_source,
        ),
        (
            "Workspace persistence gaps",
            "Missing local folder or database health checks would make recovery unclear.",
            "medium",
            "Dev",
            "resolved",
            "Expose workspace health through API responses.",
            architecture_source,
        ),
    ]:
        risk = repository.create_entity(
            conn,
            "risk",
            workspace_id,
            {
                "title": title,
                "description": description,
                "severity": severity,
                "owner": owner,
                "status": status,
                "mitigation": mitigation,
                "record_state": "accepted",
                "source_origin": "extracted",
            },
            manual=False,
        )
        risks.append(risk)
        repository.create_evidence_reference(
            conn,
            workspace_id=workspace_id,
            source_id=source["id"],
            target_entity_type="risk",
            target_entity_id=risk["id"],
            evidence_text=description,
            location_hint="seed excerpt",
        )

    meeting = repository.create_entity(
        conn,
        "meeting",
        workspace_id,
        {
            "title": "Pulse P0 Planning Review",
            "meeting_date": "2026-05-03",
            "description": "Confirm private beta scope, review cited Ask AI behavior, and assign remaining source ingestion follow-ups.",
            "attendees": ["Rina", "Dev", "Maya"],
        },
    )
    for target_type, target_id in [
        ("decision", private_beta["id"]),
        ("decision", citations_required["id"]),
        ("commitment", commitments[0]["id"]),
        ("commitment", commitments[1]["id"]),
        ("risk", risks[0]["id"]),
    ]:
        repository.link_record(conn, "meeting", meeting["id"], target_type, target_id)
    repository.create_evidence_reference(
        conn,
        workspace_id=workspace_id,
        source_id=followup_source["id"],
        target_entity_type="meeting",
        target_entity_id=meeting["id"],
        evidence_text="Rina, Dev, and Maya follow-ups from the planning review.",
        location_hint="meeting notes",
    )

    brief = repository.create_entity(
        conn,
        "brief",
        workspace_id,
        {
            "brief_date": "2026-05-02",
            "brief_type": "daily",
            "title": "Daily Brief",
            "summary": "Focus today on proving the local evidence loop: sources, accepted project records, risks, and cited answers.",
            "sections": {
                "what_changed": [
                    "Private beta and citations are accepted decisions.",
                    "Three extracted commitments are ready for follow-up.",
                ],
                "needs_attention": [
                    "Unsupported launch claims remain a high-severity open risk.",
                    "Source ingestion error handling is still open.",
                ],
            },
        },
    )
    for target_type, target_id in [
        ("decision", private_beta["id"]),
        ("decision", citations_required["id"]),
        ("commitment", commitments[1]["id"]),
        ("risk", risks[0]["id"]),
        ("meeting", meeting["id"]),
    ]:
        repository.link_record(conn, "brief", brief["id"], target_type, target_id)
    repository.create_evidence_reference(
        conn,
        workspace_id=workspace_id,
        source_id=launch_source["id"],
        target_entity_type="brief",
        target_entity_id=brief["id"],
        evidence_text="The launch plan should emphasize trust.",
        location_hint="launch notes",
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
