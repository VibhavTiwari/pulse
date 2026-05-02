from __future__ import annotations

import json
from pathlib import Path
from sqlite3 import Connection, Row
from typing import Any

from pulse.ids import make_id
from pulse.storage import ensure_pulse_dirs, workspace_db_path
from pulse.time import utc_now


RECORD_STATES = {"suggested", "accepted", "rejected"}
SOURCE_PROCESSING_STATUSES = {"pending", "ready", "failed"}
DECISION_STATUSES = {"active", "inactive"}
COMMITMENT_STATUSES = {"open", "done", "overdue", "blocked"}
RISK_SEVERITIES = {"low", "medium", "high", "critical"}
RISK_STATUSES = {"open", "mitigated", "resolved"}
BRIEF_TYPES = {"daily"}

ENTITY_CONFIG = {
    "decision": {
        "table": "decisions",
        "prefix": "dec",
        "required": ("title", "context", "decision_date", "owner", "status"),
        "enums": {"status": DECISION_STATUSES, "record_state": RECORD_STATES},
        "defaults": {"status": "active", "record_state": "accepted"},
        "order": "decision_date",
    },
    "commitment": {
        "table": "commitments",
        "prefix": "com",
        "required": ("title", "owner", "status"),
        "enums": {"status": COMMITMENT_STATUSES, "record_state": RECORD_STATES},
        "defaults": {"status": "open", "record_state": "accepted", "due_date_known": False},
        "order": "due_date",
    },
    "risk": {
        "table": "risks",
        "prefix": "risk",
        "required": ("title", "description", "severity", "owner", "status"),
        "enums": {"severity": RISK_SEVERITIES, "status": RISK_STATUSES, "record_state": RECORD_STATES},
        "defaults": {"severity": "medium", "status": "open", "record_state": "accepted"},
        "order": "updated_at",
    },
    "meeting": {
        "table": "meetings",
        "prefix": "mtg",
        "required": ("title", "meeting_date"),
        "enums": {},
        "defaults": {},
        "order": "meeting_date",
    },
    "brief": {
        "table": "briefs",
        "prefix": "brief",
        "required": ("title", "brief_date", "brief_type", "summary"),
        "enums": {"brief_type": BRIEF_TYPES},
        "defaults": {"brief_type": "daily", "sections_json": "{}"},
        "order": "brief_date",
    },
}

TARGET_TABLES = {key: value["table"] for key, value in ENTITY_CONFIG.items()}

LINK_TABLES = {
    ("meeting", "decision"): ("meeting_decisions", "meeting_id", "decision_id"),
    ("meeting", "commitment"): ("meeting_commitments", "meeting_id", "commitment_id"),
    ("meeting", "risk"): ("meeting_risks", "meeting_id", "risk_id"),
    ("brief", "decision"): ("brief_decisions", "brief_id", "decision_id"),
    ("brief", "commitment"): ("brief_commitments", "brief_id", "commitment_id"),
    ("brief", "risk"): ("brief_risks", "brief_id", "risk_id"),
    ("brief", "meeting"): ("brief_meetings", "brief_id", "meeting_id"),
}


def row_to_dict(row: Row | None) -> dict[str, Any] | None:
    return dict(row) if row is not None else None


def _json_load(value: str | None, fallback: Any) -> Any:
    if not value:
        return fallback
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return fallback


def _clean(value: Any) -> Any:
    if isinstance(value, str):
        return value.strip()
    return value


def _table_columns(conn: Connection, table: str) -> set[str]:
    return {row["name"] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _require_nonblank(data: dict[str, Any], fields: tuple[str, ...]) -> None:
    for field in fields:
        value = data.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            raise ValueError(f"{field} is required")


def _validate_enum(field: str, value: Any, allowed: set[str]) -> None:
    if value not in allowed:
        choices = ", ".join(sorted(allowed))
        raise ValueError(f"{field} must be one of: {choices}")


def _ensure_workspace(conn: Connection, workspace_id: str) -> dict[str, Any]:
    workspace = get_workspace(conn, workspace_id)
    if not workspace:
        raise ValueError("Workspace not found")
    return workspace


def workspace_health(conn: Connection, workspace: dict[str, Any]) -> dict[str, Any]:
    root = Path(workspace["root_path"])
    pulse_dir = root / ".pulse"
    source_count = conn.execute(
        "SELECT COUNT(*) AS count FROM sources WHERE workspace_id = ? AND status != 'deleted'",
        (workspace["id"],),
    ).fetchone()["count"]
    risk_count = conn.execute(
        "SELECT COUNT(*) AS count FROM risks WHERE workspace_id = ? AND record_state = 'accepted'",
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
        "risk_count": risk_count,
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
    file_path: str = "",
    original_filename: str = "",
    mime_type: str | None = None,
    content_hash: str = "",
    status: str | None = None,
    origin: str = "manual_upload",
    source_date: str | None = None,
    text_content: str | None = None,
    metadata: dict[str, Any] | None = None,
    processing_status: str | None = None,
) -> dict[str, Any]:
    _ensure_workspace(conn, workspace_id)
    payload = {
        "title": _clean(title),
        "source_type": _clean(source_type),
        "origin": _clean(origin),
        "processing_status": processing_status or status or "pending",
    }
    if payload["processing_status"] == "indexed":
        payload["processing_status"] = "ready"
    _require_nonblank(payload, ("title", "source_type", "origin", "processing_status"))
    _validate_enum("processing_status", payload["processing_status"], SOURCE_PROCESSING_STATUSES)
    if payload["processing_status"] == "ready" and not (text_content or "").strip():
        raise ValueError("ready sources must include text_content")

    now = utc_now()
    source_id = make_id("src")
    conn.execute(
        """
        INSERT INTO sources(
          id, workspace_id, title, source_type, origin, source_date, text_content,
          metadata_json, file_path, original_filename, mime_type, content_hash,
          status, processing_status, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            source_id,
            workspace_id,
            payload["title"],
            payload["source_type"],
            payload["origin"],
            source_date,
            text_content,
            json.dumps(metadata or {}),
            file_path,
            original_filename,
            mime_type,
            content_hash,
            payload["processing_status"],
            payload["processing_status"],
            now,
            now,
        ),
    )
    return get_source(conn, source_id) or {}


def update_source_status(conn: Connection, source_id: str, status: str, error_message: str | None = None) -> None:
    processing_status = "ready" if status == "indexed" else status
    if processing_status not in SOURCE_PROCESSING_STATUSES:
        raise ValueError("processing_status must be pending, ready, or failed")
    conn.execute(
        "UPDATE sources SET status = ?, processing_status = ?, error_message = ?, updated_at = ? WHERE id = ?",
        (processing_status, processing_status, error_message, utc_now(), source_id),
    )


def get_source(conn: Connection, source_id: str, include_chunks: bool = False) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM sources WHERE id = ?", (source_id,)).fetchone()
    source = row_to_dict(row)
    if source:
        source["metadata"] = _json_load(source.get("metadata_json"), {})
    if source and include_chunks:
        source["chunks"] = [
            dict(chunk)
            for chunk in conn.execute(
                "SELECT * FROM source_chunks WHERE source_id = ? ORDER BY chunk_index",
                (source_id,),
            ).fetchall()
        ]
    return source


def list_sources(
    conn: Connection,
    workspace_id: str,
    processing_status: str | None = None,
) -> list[dict[str, Any]]:
    _ensure_workspace(conn, workspace_id)
    params: list[Any] = [workspace_id]
    where = ["s.workspace_id = ?", "s.status != 'deleted'"]
    if processing_status:
        _validate_enum("processing_status", processing_status, SOURCE_PROCESSING_STATUSES)
        where.append("s.processing_status = ?")
        params.append(processing_status)
    rows = conn.execute(
        f"""
        SELECT s.*, COUNT(c.id) AS chunk_count
        FROM sources s
        LEFT JOIN source_chunks c ON c.source_id = s.id
        WHERE {' AND '.join(where)}
        GROUP BY s.id
        ORDER BY s.created_at DESC
        """,
        params,
    ).fetchall()
    return [dict(row) for row in rows]


def delete_source(conn: Connection, source_id: str) -> dict[str, Any] | None:
    source = get_source(conn, source_id)
    if not source:
        return None
    conn.execute("UPDATE sources SET status = 'deleted', updated_at = ? WHERE id = ?", (utc_now(), source_id))
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
    conn.execute(
        "UPDATE sources SET text_content = ?, updated_at = ? WHERE id = ?",
        ("\n\n".join(chunks), now, source_id),
    )


def _normalize_entity_payload(entity_type: str, data: dict[str, Any], manual: bool = True) -> dict[str, Any]:
    if entity_type not in ENTITY_CONFIG:
        raise ValueError("Unsupported entity type")
    config = ENTITY_CONFIG[entity_type]
    payload = {**config["defaults"], **{key: _clean(value) for key, value in data.items() if value is not None}}
    if manual and entity_type in {"decision", "commitment", "risk"}:
        payload.setdefault("record_state", "accepted")
    for field, allowed in config["enums"].items():
        if field in payload:
            _validate_enum(field, payload[field], allowed)
    _require_nonblank(payload, config["required"])
    if "record_state" in config["enums"]:
        payload.setdefault("record_state", "accepted")
    if entity_type == "decision":
        payload["summary"] = payload.get("summary") or payload["context"]
        payload["rationale"] = payload.get("rationale") or payload["context"]
    if entity_type == "commitment":
        payload["due_date_known"] = bool(payload.get("due_date_known"))
        if payload["due_date_known"] and not payload.get("due_date"):
            raise ValueError("due_date is required when due_date_known is true")
    if entity_type == "meeting":
        payload["agenda"] = payload.get("agenda") or payload.get("description") or ""
        payload["attendees_json"] = json.dumps(payload.get("attendees", []))
        payload.pop("attendees", None)
    if entity_type == "brief":
        sections = payload.get("sections", payload.get("sections_json", {}))
        payload["sections_json"] = sections if isinstance(sections, str) else json.dumps(sections)
        payload.pop("sections", None)
    return payload


def create_entity(
    conn: Connection,
    entity_type: str,
    workspace_id: str,
    data: dict[str, Any],
    manual: bool = True,
) -> dict[str, Any]:
    _ensure_workspace(conn, workspace_id)
    payload = _normalize_entity_payload(entity_type, data, manual=manual)
    config = ENTITY_CONFIG[entity_type]
    now = utc_now()
    record_id = make_id(config["prefix"])
    fields = ["id", "workspace_id", "created_at", "updated_at", *payload.keys()]
    values = [record_id, workspace_id, now, now, *payload.values()]
    placeholders = ", ".join("?" for _ in fields)
    conn.execute(
        f"INSERT INTO {config['table']}({', '.join(fields)}) VALUES ({placeholders})",
        values,
    )
    return get_entity(conn, entity_type, record_id) or {}


def update_entity(conn: Connection, entity_type: str, record_id: str, data: dict[str, Any]) -> dict[str, Any] | None:
    current = get_entity(conn, entity_type, record_id, include_links=False)
    if not current:
        return None
    if "record_state" in data and current.get("record_state") == "rejected" and data["record_state"] == "accepted":
        raise ValueError("Use the explicit review endpoint to restore rejected records")
    payload = _normalize_entity_payload(entity_type, {**current, **data}, manual=False)
    config = ENTITY_CONFIG[entity_type]
    columns = _table_columns(conn, config["table"])
    allowed_fields = [
        key
        for key in payload.keys()
        if key in columns and key not in {"id", "workspace_id", "created_at", "updated_at"}
    ]
    assignments = ", ".join(f"{field} = ?" for field in allowed_fields)
    conn.execute(
        f"UPDATE {config['table']} SET {assignments}, updated_at = ? WHERE id = ?",
        [payload[field] for field in allowed_fields] + [utc_now(), record_id],
    )
    return get_entity(conn, entity_type, record_id)


def list_entities(conn: Connection, entity_type: str, workspace_id: str, filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    _ensure_workspace(conn, workspace_id)
    if entity_type not in ENTITY_CONFIG:
        raise ValueError("Unsupported entity type")
    config = ENTITY_CONFIG[entity_type]
    filters = filters or {}
    params: list[Any] = [workspace_id]
    where = ["workspace_id = ?"]
    if entity_type in {"decision", "commitment", "risk"}:
        state = filters.get("record_state", "accepted")
        _validate_enum("record_state", state, RECORD_STATES)
        where.append("record_state = ?")
        params.append(state)
    filter_fields = {
        "decision": ("status", "owner"),
        "commitment": ("status", "owner", "due_date"),
        "risk": ("severity", "status", "owner"),
        "meeting": ("meeting_date",),
        "brief": ("brief_date", "brief_type"),
    }.get(entity_type, ())
    for field in filter_fields:
        if filters.get(field):
            where.append(f"{field} = ?")
            params.append(filters[field])
    rows = conn.execute(
        f"""
        SELECT * FROM {config['table']}
        WHERE {' AND '.join(where)}
        ORDER BY {config['order']} DESC, created_at DESC
        """,
        params,
    ).fetchall()
    return [_shape_entity(dict(row), entity_type) for row in rows]


def get_entity(conn: Connection, entity_type: str, record_id: str, include_links: bool = True) -> dict[str, Any] | None:
    if entity_type not in ENTITY_CONFIG:
        raise ValueError("Unsupported entity type")
    table = ENTITY_CONFIG[entity_type]["table"]
    row = conn.execute(f"SELECT * FROM {table} WHERE id = ?", (record_id,)).fetchone()
    record = _shape_entity(row_to_dict(row), entity_type)
    if record and include_links:
        record["evidence"] = list_evidence_for_record(conn, entity_type, record_id)
        if entity_type == "meeting":
            record["decisions"] = _linked_records(conn, "meeting", record_id, "decision")
            record["commitments"] = _linked_records(conn, "meeting", record_id, "commitment")
            record["risks"] = _linked_records(conn, "meeting", record_id, "risk")
        if entity_type == "brief":
            record["decisions"] = _linked_records(conn, "brief", record_id, "decision")
            record["commitments"] = _linked_records(conn, "brief", record_id, "commitment")
            record["risks"] = _linked_records(conn, "brief", record_id, "risk")
            record["meetings"] = _linked_records(conn, "brief", record_id, "meeting")
    return record


def _shape_entity(record: dict[str, Any] | None, entity_type: str) -> dict[str, Any] | None:
    if not record:
        return None
    if entity_type == "decision":
        record["summary"] = record.get("summary") or record.get("context", "")
    if entity_type == "commitment":
        record["due_date_known"] = bool(record.get("due_date_known"))
    if entity_type == "meeting":
        record["description"] = record.get("description") or record.get("agenda")
        record["attendees"] = _json_load(record.get("attendees_json"), [])
    if entity_type == "brief":
        record["sections"] = _json_load(record.get("sections_json"), {})
    return record


def transition_record_state(conn: Connection, entity_type: str, record_id: str, record_state: str) -> dict[str, Any] | None:
    if entity_type not in {"decision", "commitment", "risk"}:
        raise ValueError("Only decisions, commitments, and risks support review state")
    _validate_enum("record_state", record_state, RECORD_STATES)
    config = ENTITY_CONFIG[entity_type]
    conn.execute(
        f"UPDATE {config['table']} SET record_state = ?, updated_at = ? WHERE id = ?",
        (record_state, utc_now(), record_id),
    )
    return get_entity(conn, entity_type, record_id)


def _target_exists_in_workspace(conn: Connection, target_type: str, target_id: str, workspace_id: str) -> bool:
    table = TARGET_TABLES.get(target_type)
    if not table:
        raise ValueError("Unsupported evidence target type")
    row = conn.execute(
        f"SELECT 1 FROM {table} WHERE id = ? AND workspace_id = ?",
        (target_id, workspace_id),
    ).fetchone()
    return row is not None


def create_evidence_reference(
    conn: Connection,
    *,
    workspace_id: str,
    source_id: str,
    target_entity_type: str,
    target_entity_id: str,
    evidence_text: str | None = None,
    location_hint: str | None = None,
) -> dict[str, Any]:
    _ensure_workspace(conn, workspace_id)
    source = get_source(conn, source_id)
    if not source or source["workspace_id"] != workspace_id:
        raise ValueError("Evidence source must belong to the same workspace")
    if not _target_exists_in_workspace(conn, target_entity_type, target_entity_id, workspace_id):
        raise ValueError("Evidence target must belong to the same workspace")
    now = utc_now()
    evidence_id = make_id("evd")
    conn.execute(
        """
        INSERT INTO evidence_references(
          id, workspace_id, source_id, target_entity_type, target_entity_id,
          evidence_text, location_hint, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (evidence_id, workspace_id, source_id, target_entity_type, target_entity_id, evidence_text, location_hint, now),
    )
    return get_evidence_reference(conn, evidence_id) or {}


def get_evidence_reference(conn: Connection, evidence_id: str) -> dict[str, Any] | None:
    row = conn.execute(
        """
        SELECT e.*, s.title AS source_title, s.source_type
        FROM evidence_references e
        JOIN sources s ON s.id = e.source_id
        WHERE e.id = ?
        """,
        (evidence_id,),
    ).fetchone()
    return row_to_dict(row)


def list_evidence_for_record(conn: Connection, target_entity_type: str, target_entity_id: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT e.*, s.title AS source_title, s.source_type
        FROM evidence_references e
        JOIN sources s ON s.id = e.source_id
        WHERE e.target_entity_type = ? AND e.target_entity_id = ?
        ORDER BY e.created_at DESC
        """,
        (target_entity_type, target_entity_id),
    ).fetchall()
    return [dict(row) for row in rows]


def list_records_for_source(conn: Connection, source_id: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT * FROM evidence_references WHERE source_id = ? ORDER BY created_at DESC",
        (source_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def delete_evidence_reference(conn: Connection, evidence_id: str) -> bool:
    cursor = conn.execute("DELETE FROM evidence_references WHERE id = ?", (evidence_id,))
    return cursor.rowcount > 0


def link_record(conn: Connection, parent_type: str, parent_id: str, child_type: str, child_id: str) -> dict[str, Any]:
    key = (parent_type, child_type)
    if key not in LINK_TABLES:
        raise ValueError("Unsupported relationship")
    parent = get_entity(conn, parent_type, parent_id, include_links=False)
    child = get_entity(conn, child_type, child_id, include_links=False)
    if not parent or not child:
        raise ValueError("Linked records must exist")
    if parent["workspace_id"] != child["workspace_id"]:
        raise ValueError("Linked records must belong to the same workspace")
    table, parent_col, child_col = LINK_TABLES[key]
    conn.execute(
        f"INSERT OR IGNORE INTO {table}({parent_col}, {child_col}, workspace_id, created_at) VALUES (?, ?, ?, ?)",
        (parent_id, child_id, parent["workspace_id"], utc_now()),
    )
    return get_entity(conn, parent_type, parent_id) or parent


def _linked_records(conn: Connection, parent_type: str, parent_id: str, child_type: str) -> list[dict[str, Any]]:
    table, parent_col, child_col = LINK_TABLES[(parent_type, child_type)]
    child_table = ENTITY_CONFIG[child_type]["table"]
    rows = conn.execute(
        f"""
        SELECT c.*
        FROM {child_table} c
        JOIN {table} l ON l.{child_col} = c.id
        WHERE l.{parent_col} = ?
        ORDER BY c.created_at DESC
        """,
        (parent_id,),
    ).fetchall()
    return [_shape_entity(dict(row), child_type) for row in rows]


def list_table(conn: Connection, table: str, workspace_id: str, filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    table_to_entity = {
        "decisions": "decision",
        "commitments": "commitment",
        "risks": "risk",
        "briefs": "brief",
        "meetings": "meeting",
    }
    if table in table_to_entity:
        return list_entities(conn, table_to_entity[table], workspace_id, filters)
    if table != "ai_answers":
        raise ValueError("Unsupported table")
    rows = conn.execute(
        "SELECT * FROM ai_answers WHERE workspace_id = ? ORDER BY created_at DESC",
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
