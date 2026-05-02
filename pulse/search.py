from __future__ import annotations

import re
from sqlite3 import Connection
from typing import Any


STOP_WORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "about",
    "by",
    "for",
    "from",
    "have",
    "how",
    "in",
    "is",
    "it",
    "of",
    "on",
    "or",
    "our",
    "that",
    "the",
    "to",
    "we",
    "what",
    "with",
}


def tokenize(text: str) -> list[str]:
    return [token for token in re.findall(r"[a-z0-9]+", text.lower()) if token not in STOP_WORDS and len(token) > 2]


def score_chunk(question_tokens: set[str], text: str) -> int:
    lower = text.lower()
    tokens = tokenize(text)
    score = sum(3 for token in question_tokens if token in tokens)
    score += sum(lower.count(token) for token in question_tokens)
    return score


def search_chunks(conn: Connection, workspace_id: str, question: str, limit: int = 5) -> list[dict[str, Any]]:
    question_tokens = set(tokenize(question))
    if not question_tokens:
        return []
    rows = conn.execute(
        """
        SELECT c.id AS chunk_id, c.source_id, c.chunk_index, c.text, s.title AS source_title
        FROM source_chunks c
        JOIN sources s ON s.id = c.source_id
        WHERE c.workspace_id = ? AND s.status = 'indexed'
        """,
        (workspace_id,),
    ).fetchall()
    ranked = []
    for row in rows:
        item = dict(row)
        item["score"] = score_chunk(question_tokens, item["text"])
        if item["score"] > 0:
            ranked.append(item)
    ranked.sort(key=lambda item: item["score"], reverse=True)
    return ranked[:limit]


def quote_from(text: str, max_chars: int = 260) -> str:
    clean = re.sub(r"\s+", " ", text).strip()
    if len(clean) <= max_chars:
        return clean
    return clean[: max_chars - 1].rsplit(" ", 1)[0] + "..."
