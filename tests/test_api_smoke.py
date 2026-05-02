from __future__ import annotations

from fastapi.testclient import TestClient

from apps.api.app.main import app
from pulse.seed import reset_demo_data


def test_demo_workspace_sources_and_cited_answer() -> None:
    reset_demo_data()
    client = TestClient(app)

    health = client.get("/api/health")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"

    workspaces = client.get("/api/workspaces")
    assert workspaces.status_code == 200
    workspace = workspaces.json()[0]

    sources = client.get(f"/api/workspaces/{workspace['id']}/sources")
    assert sources.status_code == 200
    assert len(sources.json()) >= 3

    answer = client.post(
        f"/api/workspaces/{workspace['id']}/ask",
        json={"question": "What decisions have we made about the launch plan?"},
    )
    assert answer.status_code == 200
    body = answer.json()
    assert body["answer_id"] if "answer_id" in body else body["id"]
    assert body["citations"]


def test_static_index_and_docs_are_available() -> None:
    reset_demo_data()
    client = TestClient(app)

    assert client.get("/").status_code == 200
    assert client.get("/docs").status_code == 200


def test_upload_and_delete_mark_source_inactive() -> None:
    reset_demo_data()
    client = TestClient(app)
    workspace = client.get("/api/workspaces").json()[0]

    upload = client.post(
        f"/api/workspaces/{workspace['id']}/sources",
        files={"file": ("notes.md", b"# Notes\n\nThe mobile beta must keep citations visible.", "text/markdown")},
    )
    assert upload.status_code == 200
    source = upload.json()
    assert source["status"] == "indexed"
    assert source["chunks"]

    deleted = client.delete(f"/api/sources/{source['id']}")
    assert deleted.status_code == 200
    assert deleted.json()["status"] == "deleted"

    active_sources = client.get(f"/api/workspaces/{workspace['id']}/sources").json()
    assert all(item["id"] != source["id"] for item in active_sources)
