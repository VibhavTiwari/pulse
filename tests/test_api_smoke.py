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
    assert source["processing_status"] == "ready"
    assert source["chunks"]

    deleted = client.delete(f"/api/sources/{source['id']}")
    assert deleted.status_code == 200
    assert deleted.json()["status"] == "deleted"

    active_sources = client.get(f"/api/workspaces/{workspace['id']}/sources").json()
    assert all(item["id"] != source["id"] for item in active_sources)


def test_p0_data_model_review_state_evidence_and_links() -> None:
    reset_demo_data()
    client = TestClient(app)
    workspace = client.get("/api/workspaces").json()[0]
    workspace_id = workspace["id"]
    source = client.get(f"/api/workspaces/{workspace_id}/sources").json()[0]

    suggested = client.post(
        f"/api/workspaces/{workspace_id}/decisions",
        json={
            "title": "Use accepted records for project truth",
            "context": "Suggested records must stay out of official views until accepted.",
            "decision_date": "2026-05-02",
            "owner": "Dev",
            "status": "active",
            "record_state": "suggested",
            "source_origin": "extracted",
        },
    )
    assert suggested.status_code == 200
    decision = suggested.json()

    accepted_decisions = client.get(f"/api/workspaces/{workspace_id}/decisions").json()
    assert all(item["id"] != decision["id"] for item in accepted_decisions)

    evidence = client.post(
        f"/api/workspaces/{workspace_id}/evidence",
        json={
            "source_id": source["id"],
            "target_entity_type": "decision",
            "target_entity_id": decision["id"],
            "evidence_text": "Suggested records must stay separate from accepted truth.",
            "location_hint": "test",
        },
    )
    assert evidence.status_code == 200

    accepted = client.post(f"/api/decisions/{decision['id']}/accept")
    assert accepted.status_code == 200
    assert accepted.json()["record_state"] == "accepted"

    detail = client.get(f"/api/decisions/{decision['id']}").json()
    assert detail["evidence"][0]["source_id"] == source["id"]

    meeting = client.post(
        f"/api/workspaces/{workspace_id}/meetings",
        json={"title": "Data model review", "meeting_date": "2026-05-02", "description": "Review project truth links."},
    ).json()
    linked = client.post(f"/api/meetings/{meeting['id']}/links/decision/{decision['id']}")
    assert linked.status_code == 200
    assert linked.json()["decisions"][0]["id"] == decision["id"]


def test_p0_validation_rejects_invalid_commitment_and_cross_workspace_evidence() -> None:
    reset_demo_data()
    client = TestClient(app)
    workspace = client.get("/api/workspaces").json()[0]
    workspace_id = workspace["id"]
    source = client.get(f"/api/workspaces/{workspace_id}/sources").json()[0]

    invalid_commitment = client.post(
        f"/api/workspaces/{workspace_id}/commitments",
        json={
            "title": "Commit without due date",
            "owner": "Dev",
            "due_date_known": True,
            "status": "open",
        },
    )
    assert invalid_commitment.status_code == 400

    other_workspace = client.post("/api/workspaces", json={"name": "Other Workspace"}).json()
    risk = client.post(
        f"/api/workspaces/{other_workspace['id']}/risks",
        json={
            "title": "Cross workspace risk",
            "description": "Should not accept evidence from another workspace.",
            "severity": "high",
            "owner": "Dev",
            "status": "open",
        },
    ).json()

    cross_workspace_evidence = client.post(
        f"/api/workspaces/{other_workspace['id']}/evidence",
        json={
            "source_id": source["id"],
            "target_entity_type": "risk",
            "target_entity_id": risk["id"],
        },
    )
    assert cross_workspace_evidence.status_code == 400
