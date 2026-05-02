from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from pulse.settings import settings
from pulse.storage import ensure_pulse_dirs


SCHEMA_VERSION = 2


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    path = db_path or settings.db_path
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


@contextmanager
def get_db() -> Iterator[sqlite3.Connection]:
    conn = connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def _add_column(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    if column not in _columns(conn, table):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def _migrate_existing_tables(conn: sqlite3.Connection) -> None:
    _add_column(conn, "sources", "origin", "TEXT NOT NULL DEFAULT 'manual_upload'")
    _add_column(conn, "sources", "source_date", "TEXT")
    _add_column(conn, "sources", "text_content", "TEXT")
    _add_column(conn, "sources", "metadata_json", "TEXT NOT NULL DEFAULT '{}'")
    _add_column(conn, "sources", "processing_status", "TEXT NOT NULL DEFAULT 'pending'")
    conn.execute(
        """
        UPDATE sources
        SET processing_status = CASE
          WHEN status IN ('indexed', 'ready') THEN 'ready'
          WHEN status IN ('uploaded', 'processing', 'pending') THEN 'pending'
          WHEN status = 'failed' THEN 'failed'
          ELSE processing_status
        END
        """
    )

    _add_column(conn, "decisions", "context", "TEXT NOT NULL DEFAULT ''")
    _add_column(conn, "decisions", "decision_date", "TEXT")
    _add_column(conn, "decisions", "owner", "TEXT NOT NULL DEFAULT 'Unassigned'")
    _add_column(conn, "decisions", "record_state", "TEXT NOT NULL DEFAULT 'accepted'")
    _add_column(conn, "decisions", "source_origin", "TEXT")
    conn.execute("UPDATE decisions SET context = summary WHERE context = '' AND summary IS NOT NULL")
    conn.execute("UPDATE decisions SET decision_date = substr(created_at, 1, 10) WHERE decision_date IS NULL")
    conn.execute("UPDATE decisions SET status = 'active' WHERE status NOT IN ('active', 'inactive')")

    _add_column(conn, "commitments", "title", "TEXT NOT NULL DEFAULT ''")
    _add_column(conn, "commitments", "due_date_known", "INTEGER NOT NULL DEFAULT 0")
    _add_column(conn, "commitments", "record_state", "TEXT NOT NULL DEFAULT 'accepted'")
    _add_column(conn, "commitments", "source_origin", "TEXT")
    conn.execute("UPDATE commitments SET title = description WHERE title = '' AND description IS NOT NULL")
    conn.execute("UPDATE commitments SET due_date_known = 1 WHERE due_date IS NOT NULL")

    _add_column(conn, "meetings", "description", "TEXT")
    conn.execute("UPDATE meetings SET description = agenda WHERE description IS NULL AND agenda IS NOT NULL")

    _add_column(conn, "briefs", "brief_type", "TEXT NOT NULL DEFAULT 'daily'")
    _add_column(conn, "briefs", "sections_json", "TEXT NOT NULL DEFAULT '{}'")
    _add_column(conn, "briefs", "updated_at", "TEXT")
    conn.execute("UPDATE briefs SET updated_at = created_at WHERE updated_at IS NULL")


def init_db(db_path: Path | None = None) -> None:
    ensure_pulse_dirs((db_path or settings.db_path).parent.parent)
    with connect(db_path) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
              version INTEGER PRIMARY KEY,
              applied_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workspaces (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL CHECK (trim(name) != ''),
              root_path TEXT NOT NULL CHECK (trim(root_path) != ''),
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sources (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL CHECK (trim(title) != ''),
              source_type TEXT NOT NULL CHECK (trim(source_type) != ''),
              origin TEXT NOT NULL DEFAULT 'manual_upload' CHECK (trim(origin) != ''),
              source_date TEXT,
              text_content TEXT,
              metadata_json TEXT NOT NULL DEFAULT '{}',
              file_path TEXT NOT NULL DEFAULT '',
              original_filename TEXT NOT NULL DEFAULT '',
              mime_type TEXT,
              content_hash TEXT NOT NULL DEFAULT '',
              status TEXT NOT NULL DEFAULT 'pending',
              processing_status TEXT NOT NULL DEFAULT 'pending' CHECK (processing_status IN ('pending', 'ready', 'failed')),
              error_message TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS source_chunks (
              id TEXT PRIMARY KEY,
              source_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              chunk_index INTEGER NOT NULL,
              text TEXT NOT NULL CHECK (trim(text) != ''),
              metadata_json TEXT NOT NULL DEFAULT '{}',
              created_at TEXT NOT NULL,
              FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS ai_answers (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              question TEXT NOT NULL,
              answer TEXT NOT NULL,
              model_name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS citations (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              answer_id TEXT NOT NULL,
              source_id TEXT NOT NULL,
              chunk_id TEXT NOT NULL,
              quote TEXT NOT NULL,
              source_title TEXT NOT NULL,
              source_location TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (answer_id) REFERENCES ai_answers(id) ON DELETE CASCADE,
              FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE,
              FOREIGN KEY (chunk_id) REFERENCES source_chunks(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS decisions (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL CHECK (trim(title) != ''),
              summary TEXT NOT NULL DEFAULT '',
              context TEXT NOT NULL DEFAULT '' CHECK (trim(context) != ''),
              decision_date TEXT,
              owner TEXT NOT NULL DEFAULT 'Unassigned' CHECK (trim(owner) != ''),
              status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
              record_state TEXT NOT NULL DEFAULT 'accepted' CHECK (record_state IN ('suggested', 'accepted', 'rejected')),
              source_origin TEXT,
              rationale TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS commitments (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '' CHECK (trim(title) != ''),
              description TEXT,
              owner TEXT NOT NULL CHECK (trim(owner) != ''),
              due_date TEXT,
              due_date_known INTEGER NOT NULL DEFAULT 0 CHECK (due_date_known IN (0, 1)),
              status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'overdue', 'blocked')),
              record_state TEXT NOT NULL DEFAULT 'accepted' CHECK (record_state IN ('suggested', 'accepted', 'rejected')),
              source_origin TEXT,
              source_id TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              CHECK (due_date_known = 0 OR due_date IS NOT NULL),
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS risks (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL CHECK (trim(title) != ''),
              description TEXT NOT NULL CHECK (trim(description) != ''),
              severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
              owner TEXT NOT NULL CHECK (trim(owner) != ''),
              status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'mitigated', 'resolved')),
              mitigation TEXT,
              record_state TEXT NOT NULL DEFAULT 'accepted' CHECK (record_state IN ('suggested', 'accepted', 'rejected')),
              source_origin TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS meetings (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL CHECK (trim(title) != ''),
              meeting_date TEXT NOT NULL,
              description TEXT,
              attendees_json TEXT NOT NULL DEFAULT '[]',
              agenda TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS briefs (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              brief_date TEXT NOT NULL,
              title TEXT NOT NULL CHECK (trim(title) != ''),
              brief_type TEXT NOT NULL DEFAULT 'daily' CHECK (brief_type IN ('daily')),
              summary TEXT NOT NULL CHECK (trim(summary) != ''),
              sections_json TEXT NOT NULL DEFAULT '{}',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS evidence_references (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              source_id TEXT NOT NULL,
              target_entity_type TEXT NOT NULL CHECK (target_entity_type IN ('decision', 'commitment', 'risk', 'meeting', 'brief')),
              target_entity_id TEXT NOT NULL,
              evidence_text TEXT,
              location_hint TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS meeting_decisions (
              meeting_id TEXT NOT NULL,
              decision_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (meeting_id, decision_id),
              FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
              FOREIGN KEY (decision_id) REFERENCES decisions(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS meeting_commitments (
              meeting_id TEXT NOT NULL,
              commitment_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (meeting_id, commitment_id),
              FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
              FOREIGN KEY (commitment_id) REFERENCES commitments(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS meeting_risks (
              meeting_id TEXT NOT NULL,
              risk_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (meeting_id, risk_id),
              FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
              FOREIGN KEY (risk_id) REFERENCES risks(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS brief_decisions (
              brief_id TEXT NOT NULL,
              decision_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (brief_id, decision_id),
              FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE,
              FOREIGN KEY (decision_id) REFERENCES decisions(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS brief_commitments (
              brief_id TEXT NOT NULL,
              commitment_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (brief_id, commitment_id),
              FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE,
              FOREIGN KEY (commitment_id) REFERENCES commitments(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS brief_risks (
              brief_id TEXT NOT NULL,
              risk_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (brief_id, risk_id),
              FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE,
              FOREIGN KEY (risk_id) REFERENCES risks(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS brief_meetings (
              brief_id TEXT NOT NULL,
              meeting_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (brief_id, meeting_id),
              FOREIGN KEY (brief_id) REFERENCES briefs(id) ON DELETE CASCADE,
              FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS runs (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              run_type TEXT NOT NULL,
              status TEXT NOT NULL,
              input_json TEXT NOT NULL DEFAULT '{}',
              output_json TEXT NOT NULL DEFAULT '{}',
              error_message TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            """
        )
        _migrate_existing_tables(conn)
        conn.executescript(
            """
            CREATE INDEX IF NOT EXISTS idx_sources_workspace ON sources(workspace_id);
            CREATE INDEX IF NOT EXISTS idx_sources_processing_status ON sources(processing_status);
            CREATE INDEX IF NOT EXISTS idx_sources_source_date ON sources(source_date);
            CREATE INDEX IF NOT EXISTS idx_chunks_workspace ON source_chunks(workspace_id);
            CREATE INDEX IF NOT EXISTS idx_answers_workspace_created ON ai_answers(workspace_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_citations_answer ON citations(answer_id);
            CREATE INDEX IF NOT EXISTS idx_decisions_workspace_state ON decisions(workspace_id, record_state);
            CREATE INDEX IF NOT EXISTS idx_decisions_date_status ON decisions(decision_date, status);
            CREATE INDEX IF NOT EXISTS idx_commitments_workspace_state ON commitments(workspace_id, record_state);
            CREATE INDEX IF NOT EXISTS idx_commitments_status_due_owner ON commitments(status, due_date, owner);
            CREATE INDEX IF NOT EXISTS idx_risks_workspace_state ON risks(workspace_id, record_state);
            CREATE INDEX IF NOT EXISTS idx_risks_severity_status_owner ON risks(severity, status, owner);
            CREATE INDEX IF NOT EXISTS idx_meetings_workspace_date ON meetings(workspace_id, meeting_date);
            CREATE INDEX IF NOT EXISTS idx_briefs_workspace_date_type ON briefs(workspace_id, brief_date, brief_type);
            CREATE INDEX IF NOT EXISTS idx_evidence_source ON evidence_references(source_id);
            CREATE INDEX IF NOT EXISTS idx_evidence_target ON evidence_references(target_entity_type, target_entity_id);
            """
        )
        conn.execute(
            "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?, datetime('now'))",
            (SCHEMA_VERSION,),
        )
