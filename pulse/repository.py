from __future__ import annotations

import json
from pathlib import Path
from sqlite3 import Connection, Row
from typing import Any

from pulse.ids import make_id
from pulse.storage import ensure_pulse_dirs, workspace_db_path
from pulse.time import utc_now


def row_to_dict(row: Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None


def workspace_health(conn: Connection, workspace: dict[str, Any]) -> dict[str, Any]:
    root = Path(workspace["root_path"])
    pulse_dir = root / ".pulse"
    source_count = conn.execute(
        "SELECT COUNT(*) AS count FROM sources WHERE workspace_id = ? AND status != 'deleted'",
        (workspace["id"],),
    ).fetchone()["count"]
    chunk_count = conn.execute(
        "SELECT COUNT(*) AS count FROM source_chunks WHERE workspace_id = ?",
        (workspace["id"],),
    ).fetchone()["count"]
    answer_count = conn.execute(
        "SELECT COUNT(*) AS count FROM ai_answers WHERE workspace_id = ?",
        (workspace["id"],),
    ).fetchone()["count"]
    return {
        "status": "ready" if pulse_dir.exists() else "missing_folder",
        "folder_exists": pulse_dir.exists(),
        "database_exists": workspace_db_path(root).exists(),
        "source_count": source_count,
        "chunk_count": chunk_count,
        "answer_count": answer_count,
    }


def enrich_workspace(conn: Connection, row: Row) -> dict[str, Any]:
    workspace = dict(row)
    workspace["database_path"] = str(workspace_db_path(workspace["root_path"]))
    workspace["health"] = workspace_health(conn, workspace)
    return workspace


def create_workspace(conn: Connection, name: str, root_path: str | None = None) -> dict[str, Any]:
    now = utc_now()
    workspace_id = make_id("ws")
    root = Path(root_path).resolve() if root_path else Path.cwd().resolve()
    pulse_dir = ensure_pulse_dirs(root)
    workspace_db_path(root).touch(exist_ok=True)
    conn.execute(
        """
        INSERT INTO workspaces(id, name, root_path, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (workspace_id, name.strip() or "Untitled Workspace", str(root), now, now),
    )
    row = conn.execute("SELECT * FROM workspaces WHERE id = ?", (workspace_id,)).fetchone()
    (pulse_dir / "indexes").mkdir(exist_ok=True)
    return enrich_workspace(conn, row)


def list_workspaces(conn: Connection) -> list[dict[str, Any]]:
    rows = conn.execute("SELECT * FROM workspaces ORDER BY created_at DESC").fetchall()
    return [enrich_workspace(conn, row) for row in rows]


def get_workspace(conn: Connection, workspace_id: str) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM workspaces WHERE id = ?", (workspace_id,)).fetchone()
    return enrich_workspace(conn, row) if row else None


def insert_source(
    conn: Connection,
    *,
    workspace_id: str,
    title: str,
    source_type: str,
    file_path: str,
    original_filename: str,
    mime_type: str | None,
    content_hash: str,
    status: str,
) -> dict[str, Any]:
    now = utc_now()
    source_id = make_id("src")
    conn.execute(
        """
        INSERT INTO sources(
          id, workspace_id, title, source_type, file_path, original_filename,
          mime_type, content_hash, status, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            source_id,
            workspace_id,
            title,
            source_type,
            file_path,
            original_filename,
            mime_type,
            content_hash,
            status,
            now,
            now,
        ),
    )
    return get_source(conn, source_id) or {}


def update_source_status(conn: Connection, source_id: str, status: str, error_message: str | None = None) -> None:
    conn.execute(
        "UPDATE sources SET status = ?, error_message = ?, updated_at = ? WHERE id = ?",
        (status, error_message, utc_now(), source_id),
    )


def get_source(conn: Connection, source_id: str, include_chunks: bool = False) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM sources WHERE id = ?", (source_id,)).fetchone()
    source = row_to_dict(row)
    if source and include_chunks:
        source["chunks"] = [
            dict(chunk)
            for chunk in conn.execute(
                "SELECT * FROM source_chunks WHERE source_id = ? ORDER BY chunk_index",
                (source_id,),
            ).fetchall()
        ]
    return source


def list_sources(conn: Connection, workspace_id: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT s.*, COUNT(c.id) AS chunk_count
        FROM sources s
        LEFT JOIN source_chunks c ON c.source_id = s.id
        WHERE s.workspace_id = ? AND s.status != 'deleted'
        GROUP BY s.id
        ORDER BY s.created_at DESC
        """,
        (workspace_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def delete_source(conn: Connection, source_id: str) -> dict[str, Any] | None:
    source = get_source(conn, source_id)
    if not source:
        return None
    update_source_status(conn, source_id, "deleted")
    return get_source(conn, source_id)


def replace_chunks(conn: Connection, source_id: str, workspace_id: str, chunks: list[str]) -> None:
    conn.execute("DELETE FROM source_chunks WHERE source_id = ?", (source_id,))
    now = utc_now()
    for index, text in enumerate(chunks):
        conn.execute(
            """
            INSERT INTO source_chunks(id, source_id, workspace_id, chunk_index, text, metadata_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                make_id("chunk"),
                source_id,
                workspace_id,
                index,
                text,
                json.dumps({"source_location": f"chunk {index + 1}"}),
                now,
            ),
        )


def list_table(conn: Connection, table: str, workspace_id: str) -> list[dict[str, Any]]:
    allowed = {"decisions", "commitments", "briefs", "meetings", "ai_answers"}
    if table not in allowed:
        raise ValueError("Unsupported table")
    order_col = "created_at"
    if table == "briefs":
        order_col = "brief_date"
    if table == "meetings":
        order_col = "meeting_date"
    rows = conn.execute(
        f"SELECT * FROM {table} WHERE workspace_id = ? ORDER BY {order_col} DESC",
        (workspace_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def insert_answer(
    conn: Connection,
    workspace_id: str,
    question: str,
    answer: str,
    model_name: str,
    citations: list[dict[str, Any]],
) -> dict[str, Any]:
    now = utc_now()
    answer_id = make_id("ans")
    conn.execute(
        "INSERT INTO ai_answers(id, workspace_id, question, answer, model_name, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (answer_id, workspace_id, question, answer, model_name, now),
    )
    for citation in citations:
        conn.execute(
            """
            INSERT INTO citations(
              id, workspace_id, answer_id, source_id, chunk_id, quote, source_title, source_location, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                make_id("cit"),
                workspace_id,
                answer_id,
                citation["source_id"],
                citation["chunk_id"],
                citation["quote"],
                citation["source_title"],
                citation["source_location"],
                now,
            ),
        )
    return get_answer(conn, answer_id) or {}


def get_answer(conn: Connection, answer_id: str) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM ai_answers WHERE id = ?", (answer_id,)).fetchone()
    answer = row_to_dict(row)
    if answer:
        answer["answer_id"] = answer["id"]
        answer["citations"] = [
            dict(row)
            for row in conn.execute(
                "SELECT * FROM citations WHERE answer_id = ? ORDER BY created_at ASC",
                (answer_id,),
            ).fetchall()
        ]
    return answer
