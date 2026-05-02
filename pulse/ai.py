from __future__ import annotations

import re
from sqlite3 import Connection

from pulse import repository
from pulse.search import quote_from, search_chunks


MODEL_NAME = "local-keyword-evidence-v0"
NO_EVIDENCE_ANSWER = "I do not have enough information in this workspace to answer that."


def _sentence_candidates(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+", re.sub(r"\s+", " ", text).strip())
    return [part.strip() for part in parts if len(part.strip()) > 40]


def compose_answer(question: str, chunks: list[dict]) -> str:
    sentences: list[str] = []
    for chunk in chunks:
        for sentence in _sentence_candidates(chunk["text"]):
            if sentence not in sentences:
                sentences.append(sentence)
            if len(sentences) >= 4:
                break
        if len(sentences) >= 4:
            break
    if not sentences:
        return NO_EVIDENCE_ANSWER
    if len(sentences) == 1:
        return sentences[0]
    return " ".join(sentences[:4])


def ask_workspace(conn: Connection, workspace_id: str, question: str) -> dict:
    chunks = search_chunks(conn, workspace_id, question)
    if not chunks:
        return repository.insert_answer(conn, workspace_id, question, NO_EVIDENCE_ANSWER, MODEL_NAME, [])

    answer = compose_answer(question, chunks)
    citations = [
        {
            "source_id": chunk["source_id"],
            "chunk_id": chunk["chunk_id"],
            "source_title": chunk["source_title"],
            "quote": quote_from(chunk["text"]),
            "source_location": f"chunk {chunk['chunk_index'] + 1}",
        }
        for chunk in chunks[:3]
    ]
    return repository.insert_answer(conn, workspace_id, question, answer, MODEL_NAME, citations)
