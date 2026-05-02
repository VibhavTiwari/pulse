from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from pulse.settings import settings
from pulse.storage import ensure_pulse_dirs


SCHEMA_VERSION = 1


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
              name TEXT NOT NULL,
              root_path TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sources (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL,
              source_type TEXT NOT NULL,
              file_path TEXT NOT NULL,
              original_filename TEXT NOT NULL,
              mime_type TEXT,
              content_hash TEXT NOT NULL,
              status TEXT NOT NULL,
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
              text TEXT NOT NULL,
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
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              status TEXT NOT NULL,
              rationale TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS commitments (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              owner TEXT NOT NULL,
              description TEXT NOT NULL,
              due_date TEXT,
              status TEXT NOT NULL,
              source_id TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
              FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS briefs (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              brief_date TEXT NOT NULL,
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS meetings (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              title TEXT NOT NULL,
              meeting_date TEXT NOT NULL,
              attendees_json TEXT NOT NULL DEFAULT '[]',
              agenda TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
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

            CREATE INDEX IF NOT EXISTS idx_sources_workspace_status ON sources(workspace_id, status);
            CREATE INDEX IF NOT EXISTS idx_chunks_workspace ON source_chunks(workspace_id);
            CREATE INDEX IF NOT EXISTS idx_answers_workspace_created ON ai_answers(workspace_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_citations_answer ON citations(answer_id);
            """
        )
        conn.execute(
            "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?, datetime('now'))",
            (SCHEMA_VERSION,),
        )
