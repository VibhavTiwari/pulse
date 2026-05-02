from __future__ import annotations

import hashlib
import re
import shutil
from pathlib import Path
from sqlite3 import Connection

from fastapi import UploadFile

from pulse import repository


SUPPORTED_EXTENSIONS = {".txt": "text", ".md": "markdown"}


def content_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_text(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError("Only .txt and .md files are supported in this P0 build.")
    return path.read_text(encoding="utf-8", errors="replace")


def chunk_text(text: str, max_chars: int = 900, overlap: int = 120) -> list[str]:
    normalized = re.sub(r"\r\n?", "\n", text).strip()
    if not normalized:
        return []
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", normalized) if part.strip()]
    chunks: list[str] = []
    current = ""
    for paragraph in paragraphs:
        candidate = f"{current}\n\n{paragraph}".strip() if current else paragraph
        if len(candidate) <= max_chars:
            current = candidate
            continue
        if current:
            chunks.append(current)
        while len(paragraph) > max_chars:
            chunks.append(paragraph[:max_chars].strip())
            paragraph = paragraph[max_chars - overlap :].strip()
        current = paragraph
    if current:
        chunks.append(current)
    return chunks


async def ingest_upload(conn: Connection, workspace: dict, upload: UploadFile) -> dict:
    filename = Path(upload.filename or "source.txt").name
    suffix = Path(filename).suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError("Only .txt and .md uploads are supported right now.")

    raw = await upload.read()
    if not raw:
        raise ValueError("Uploaded file is empty.")

    pulse_dir = Path(workspace["root_path"]) / ".pulse"
    source_dir = pulse_dir / "sources"
    source_dir.mkdir(parents=True, exist_ok=True)
    digest = content_hash(raw)
    stored_path = source_dir / f"{digest[:12]}-{filename}"
    stored_path.write_bytes(raw)

    source = repository.insert_source(
        conn,
        workspace_id=workspace["id"],
        title=Path(filename).stem,
        source_type=SUPPORTED_EXTENSIONS[suffix],
        file_path=str(stored_path),
        original_filename=filename,
        mime_type=upload.content_type,
        content_hash=digest,
        status="pending",
        origin="manual_upload",
        metadata={"filename": filename},
    )
    try:
        text = extract_text(stored_path)
        chunks = chunk_text(text)
        if not chunks:
            raise ValueError("No readable text could be extracted from this file.")
        repository.replace_chunks(conn, source["id"], workspace["id"], chunks)
        repository.update_source_status(conn, source["id"], "ready")
    except Exception as exc:
        repository.update_source_status(conn, source["id"], "failed", str(exc))
    return repository.get_source(conn, source["id"], include_chunks=True) or source


def remove_source_file(source: dict) -> None:
    path = Path(source.get("file_path", ""))
    try:
        if path.exists() and path.is_file():
            path.unlink()
    except OSError:
        pass
    legacy_dir = path.with_suffix(path.suffix + ".deleted")
    if legacy_dir.exists() and legacy_dir.is_dir():
        shutil.rmtree(legacy_dir, ignore_errors=True)
