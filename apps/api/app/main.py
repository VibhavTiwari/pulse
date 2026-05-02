from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
from collections.abc import AsyncIterator

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


@app.get("/api/workspaces/{workspace_id}/sources")
def list_sources(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        if not repository.get_workspace(conn, workspace_id):
            raise HTTPException(status_code=404, detail="Workspace not found")
        return repository.list_sources(conn, workspace_id)


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
def list_decisions(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_table(conn, "decisions", workspace_id)


@app.get("/api/workspaces/{workspace_id}/commitments")
def list_commitments(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_table(conn, "commitments", workspace_id)


@app.get("/api/workspaces/{workspace_id}/briefs")
def list_briefs(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_table(conn, "briefs", workspace_id)


@app.get("/api/workspaces/{workspace_id}/meetings")
def list_meetings(workspace_id: str) -> list[dict]:
    with get_db() as conn:
        return repository.list_table(conn, "meetings", workspace_id)
