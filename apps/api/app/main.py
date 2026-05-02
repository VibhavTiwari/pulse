from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from pulse import repository
from pulse.ai import ask_workspace
from pulse.db import get_db, init_db
from pulse.ingestion import ingest_upload, remove_source_file
from pulse.seed import reset_demo_data


class WorkspaceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    root_path: str | None = None


class AskRequest(BaseModel):
    question: str = Field(min_length=3, max_length=1000)


class TextSourceCreate(BaseModel):
    title: str = Field(min_length=1, max_length=240)
    source_type: str = Field(min_length=1, max_length=80)
    origin: str = Field(default="manual_entry", min_length=1, max_length=80)
    source_date: str | None = None
    text_content: str = Field(min_length=1)
    metadata: dict[str, Any] = Field(default_factory=dict)


class RecordPayload(BaseModel):
    title: str | None = None
    context: str | None = None
    decision_date: str | None = None
    owner: str | None = None
    status: str | None = None
    record_state: str | None = None
    source_origin: str | None = None
    rationale: str | None = None
    description: str | None = None
    due_date: str | None = None
    due_date_known: bool | None = None
    severity: str | None = None
    mitigation: str | None = None
    meeting_date: str | None = None
    attendees: list[str] | None = None
    agenda: str | None = None
    brief_date: str | None = None
    brief_type: str | None = None
    summary: str | None = None
    sections: dict[str, Any] | None = None

    def compact(self) -> dict[str, Any]:
        return {key: value for key, value in self.model_dump().items() if value is not None}


class EvidenceCreate(BaseModel):
    source_id: str
    target_entity_type: str
    target_entity_id: str
    evidence_text: str | None = None
    location_hint: str | None = None


def _bad_request(exc: ValueError) -> HTTPException:
    return HTTPException(status_code=400, detail=str(exc))


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    init_db()
    yield


app = FastAPI(title="Pulse Foundation API", version="0.1.0", lifespan=lifespan)
static_dir = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=static_dir), name="static")


@app.get("/")
def index() -> FileResponse:
    return FileResponse(static_dir / "index.html")


@app.get("/api/health")
def health() -> dict:
    init_db()
    with get_db() as conn:
        workspace_count = conn.execute("SELECT COUNT(*) AS count FROM workspaces").fetchone()["count"]
    return {"status": "ok", "workspace_count": workspace_count}


@app.post("/api/demo/reset")
def reset_demo() -> dict:
    workspace = reset_demo_data()
    return {"workspace": workspace}


@app.post("/api/workspaces")
def create_workspace(payload: WorkspaceCreate) -> dict:
    init_db()
    with get_db() as conn:
        return repository.create_workspace(conn, payload.name, payload.root_path)


@app.get("/api/workspaces")
def list_workspaces() -> list[dict]:
    init_db()
    with get_db() as conn:
        return repository.list_workspaces(conn)


@app.get("/api/workspaces/{workspace_id}")
def get_workspace(workspace_id: str) -> dict:
    with get_db() as conn:
        workspace = repository.get_workspace(conn, workspace_id)
        if not workspace:
            raise HTTPException(status_code=404, detail="Workspace not found")
        return workspace


@app.post("/api/workspaces/{workspace_id}/sources")
async def upload_source(workspace_id: str, file: UploadFile = File(...)) -> dict:
    with get_db() as conn:
        workspace = repository.get_workspace(conn, workspace_id)
        if not workspace:
            raise HTTPException(status_code=404, detail="Workspace not found")
        try:
            return await ingest_upload(conn, workspace, file)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/workspaces/{workspace_id}/sources/text")
def create_text_source(workspace_id: str, payload: TextSourceCreate) -> dict:
    with get_db() as conn:
        try:
            source = repository.insert_source(
                conn,
                workspace_id=workspace_id,
                title=payload.title,
                source_type=payload.source_type,
                origin=payload.origin,
                source_date=payload.source_date,
                text_content=payload.text_content,
                metadata=payload.metadata,
                processing_status="ready",
            )
            from pulse.ingestion import chunk_text

            repository.replace_chunks(conn, source["id"], workspace_id, chunk_text(payload.text_content))
            return repository.get_source(conn, source["id"], include_chunks=True) or source
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/workspaces/{workspace_id}/sources")
def list_sources(workspace_id: str, processing_status: str | None = None) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_sources(conn, workspace_id, processing_status)
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/sources/{source_id}")
def get_source(source_id: str) -> dict:
    with get_db() as conn:
        source = repository.get_source(conn, source_id, include_chunks=True)
        if not source:
            raise HTTPException(status_code=404, detail="Source not found")
        return source


@app.delete("/api/sources/{source_id}")
def delete_source(source_id: str) -> dict:
    with get_db() as conn:
        source = repository.get_source(conn, source_id)
        if not source:
            raise HTTPException(status_code=404, detail="Source not found")
        remove_source_file(source)
        deleted = repository.delete_source(conn, source_id)
        return deleted or source


@app.post("/api/workspaces/{workspace_id}/ask")
def ask(workspace_id: str, payload: AskRequest) -> dict:
    with get_db() as conn:
        if not repository.get_workspace(conn, workspace_id):
            raise HTTPException(status_code=404, detail="Workspace not found")
        return ask_workspace(conn, workspace_id, payload.question)


@app.get("/api/workspaces/{workspace_id}/answers")
def list_answers(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        if not repository.get_workspace(conn, workspace_id):
            raise HTTPException(status_code=404, detail="Workspace not found")
        return repository.list_table(conn, "ai_answers", workspace_id)


@app.get("/api/answers/{answer_id}")
def get_answer(answer_id: str) -> dict:
    with get_db() as conn:
        answer = repository.get_answer(conn, answer_id)
        if not answer:
            raise HTTPException(status_code=404, detail="Answer not found")
        return answer


@app.get("/api/workspaces/{workspace_id}/decisions")
def list_decisions(workspace_id: str, record_state: str = "accepted", status: str | None = None, owner: str | None = None) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_entities(conn, "decision", workspace_id, {"record_state": record_state, "status": status, "owner": owner})
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/decisions")
def create_decision(workspace_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            return repository.create_entity(conn, "decision", workspace_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/decisions/{decision_id}")
def get_decision(decision_id: str) -> dict:
    with get_db() as conn:
        decision = repository.get_entity(conn, "decision", decision_id)
        if not decision:
            raise HTTPException(status_code=404, detail="Decision not found")
        return decision


@app.patch("/api/decisions/{decision_id}")
def update_decision(decision_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            decision = repository.update_entity(conn, "decision", decision_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc
        if not decision:
            raise HTTPException(status_code=404, detail="Decision not found")
        return decision


@app.post("/api/decisions/{decision_id}/accept")
def accept_decision(decision_id: str) -> dict:
    with get_db() as conn:
        decision = repository.transition_record_state(conn, "decision", decision_id, "accepted")
        if not decision:
            raise HTTPException(status_code=404, detail="Decision not found")
        return decision


@app.post("/api/decisions/{decision_id}/reject")
def reject_decision(decision_id: str) -> dict:
    with get_db() as conn:
        decision = repository.transition_record_state(conn, "decision", decision_id, "rejected")
        if not decision:
            raise HTTPException(status_code=404, detail="Decision not found")
        return decision


@app.get("/api/workspaces/{workspace_id}/commitments")
def list_commitments(
    workspace_id: str,
    record_state: str = "accepted",
    status: str | None = None,
    owner: str | None = None,
    due_date: str | None = None,
) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_entities(
                conn,
                "commitment",
                workspace_id,
                {"record_state": record_state, "status": status, "owner": owner, "due_date": due_date},
            )
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/commitments")
def create_commitment(workspace_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            return repository.create_entity(conn, "commitment", workspace_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/commitments/{commitment_id}")
def get_commitment(commitment_id: str) -> dict:
    with get_db() as conn:
        commitment = repository.get_entity(conn, "commitment", commitment_id)
        if not commitment:
            raise HTTPException(status_code=404, detail="Commitment not found")
        return commitment


@app.patch("/api/commitments/{commitment_id}")
def update_commitment(commitment_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            commitment = repository.update_entity(conn, "commitment", commitment_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc
        if not commitment:
            raise HTTPException(status_code=404, detail="Commitment not found")
        return commitment


@app.post("/api/commitments/{commitment_id}/accept")
def accept_commitment(commitment_id: str) -> dict:
    with get_db() as conn:
        commitment = repository.transition_record_state(conn, "commitment", commitment_id, "accepted")
        if not commitment:
            raise HTTPException(status_code=404, detail="Commitment not found")
        return commitment


@app.post("/api/commitments/{commitment_id}/reject")
def reject_commitment(commitment_id: str) -> dict:
    with get_db() as conn:
        commitment = repository.transition_record_state(conn, "commitment", commitment_id, "rejected")
        if not commitment:
            raise HTTPException(status_code=404, detail="Commitment not found")
        return commitment


@app.get("/api/workspaces/{workspace_id}/risks")
def list_risks(
    workspace_id: str,
    record_state: str = "accepted",
    severity: str | None = None,
    status: str | None = None,
    owner: str | None = None,
) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_entities(
                conn,
                "risk",
                workspace_id,
                {"record_state": record_state, "severity": severity, "status": status, "owner": owner},
            )
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/risks")
def create_risk(workspace_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            return repository.create_entity(conn, "risk", workspace_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/risks/{risk_id}")
def get_risk(risk_id: str) -> dict:
    with get_db() as conn:
        risk = repository.get_entity(conn, "risk", risk_id)
        if not risk:
            raise HTTPException(status_code=404, detail="Risk not found")
        return risk


@app.patch("/api/risks/{risk_id}")
def update_risk(risk_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            risk = repository.update_entity(conn, "risk", risk_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc
        if not risk:
            raise HTTPException(status_code=404, detail="Risk not found")
        return risk


@app.post("/api/risks/{risk_id}/accept")
def accept_risk(risk_id: str) -> dict:
    with get_db() as conn:
        risk = repository.transition_record_state(conn, "risk", risk_id, "accepted")
        if not risk:
            raise HTTPException(status_code=404, detail="Risk not found")
        return risk


@app.post("/api/risks/{risk_id}/reject")
def reject_risk(risk_id: str) -> dict:
    with get_db() as conn:
        risk = repository.transition_record_state(conn, "risk", risk_id, "rejected")
        if not risk:
            raise HTTPException(status_code=404, detail="Risk not found")
        return risk


@app.get("/api/workspaces/{workspace_id}/briefs")
def list_briefs(workspace_id: str, brief_date: str | None = None, brief_type: str | None = None) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_entities(conn, "brief", workspace_id, {"brief_date": brief_date, "brief_type": brief_type})
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/briefs")
def create_brief(workspace_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            return repository.create_entity(conn, "brief", workspace_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/briefs/{brief_id}")
def get_brief(brief_id: str) -> dict:
    with get_db() as conn:
        brief = repository.get_entity(conn, "brief", brief_id)
        if not brief:
            raise HTTPException(status_code=404, detail="Brief not found")
        return brief


@app.patch("/api/briefs/{brief_id}")
def update_brief(brief_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            brief = repository.update_entity(conn, "brief", brief_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc
        if not brief:
            raise HTTPException(status_code=404, detail="Brief not found")
        return brief


@app.post("/api/briefs/{brief_id}/links/{entity_type}/{entity_id}")
def link_brief_record(brief_id: str, entity_type: str, entity_id: str) -> dict:
    with get_db() as conn:
        try:
            return repository.link_record(conn, "brief", brief_id, entity_type, entity_id)
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/workspaces/{workspace_id}/meetings")
def list_meetings(workspace_id: str, meeting_date: str | None = None) -> list[dict]:
    with get_db() as conn:
        try:
            return repository.list_entities(conn, "meeting", workspace_id, {"meeting_date": meeting_date})
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/meetings")
def create_meeting(workspace_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            return repository.create_entity(conn, "meeting", workspace_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/meetings/{meeting_id}")
def get_meeting(meeting_id: str) -> dict:
    with get_db() as conn:
        meeting = repository.get_entity(conn, "meeting", meeting_id)
        if not meeting:
            raise HTTPException(status_code=404, detail="Meeting not found")
        return meeting


@app.patch("/api/meetings/{meeting_id}")
def update_meeting(meeting_id: str, payload: RecordPayload) -> dict:
    with get_db() as conn:
        try:
            meeting = repository.update_entity(conn, "meeting", meeting_id, payload.compact())
        except ValueError as exc:
            raise _bad_request(exc) from exc
        if not meeting:
            raise HTTPException(status_code=404, detail="Meeting not found")
        return meeting


@app.post("/api/meetings/{meeting_id}/links/{entity_type}/{entity_id}")
def link_meeting_record(meeting_id: str, entity_type: str, entity_id: str) -> dict:
    with get_db() as conn:
        try:
            return repository.link_record(conn, "meeting", meeting_id, entity_type, entity_id)
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.post("/api/workspaces/{workspace_id}/evidence")
def create_evidence(workspace_id: str, payload: EvidenceCreate) -> dict:
    with get_db() as conn:
        try:
            return repository.create_evidence_reference(
                conn,
                workspace_id=workspace_id,
                source_id=payload.source_id,
                target_entity_type=payload.target_entity_type,
                target_entity_id=payload.target_entity_id,
                evidence_text=payload.evidence_text,
                location_hint=payload.location_hint,
            )
        except ValueError as exc:
            raise _bad_request(exc) from exc


@app.get("/api/evidence/{target_entity_type}/{target_entity_id}")
def list_evidence_for_record(target_entity_type: str, target_entity_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_evidence_for_record(conn, target_entity_type, target_entity_id)


@app.get("/api/sources/{source_id}/records")
def list_records_for_source(source_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_records_for_source(conn, source_id)


@app.delete("/api/evidence/{evidence_id}")
def delete_evidence(evidence_id: str) -> dict:
    with get_db() as conn:
        if not repository.delete_evidence_reference(conn, evidence_id):
            raise HTTPException(status_code=404, detail="Evidence reference not found")
        return {"deleted": True}
