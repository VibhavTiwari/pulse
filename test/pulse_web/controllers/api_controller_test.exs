defmodule PulseWeb.ApiControllerTest do
  use PulseWeb.ConnCase

  test "workspace source ask flow works through JSON APIs", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "API Workspace", root_path: "C:/tmp/api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Launch Notes",
        source_type: "document",
        origin: "manual_entry",
        text_content:
          "The launch should prioritize a focused private beta before public announcement."
      })

    source = json_response(conn, 200)
    assert source["processing_status"] == "ready"

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/ask", %{
        question: "What is the launch plan?"
      })

    answer = json_response(conn, 200)
    assert answer["answer_id"]
    assert answer["thread_id"]
    assert answer["evidence_state"] in ["strong", "weak", "mixed"]
    assert [_citation] = answer["citations"]

    conn =
      post(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/ask_threads/#{answer["thread_id"]}/messages",
        %{
          question: "What kind of beta?"
        }
      )

    follow_up = json_response(conn, 200)
    assert follow_up["thread_id"] == answer["thread_id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/ask_threads/#{answer["thread_id"]}")
    thread = json_response(conn, 200)
    assert length(thread["messages"]) == 4
  end

  test "ask API returns explicit no-evidence state without citations", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "No Evidence API", root_path: "C:/tmp/none"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/ask", %{
        question: "What is the pricing model?"
      })

    answer = json_response(conn, 200)
    assert answer["evidence_state"] == "none"
    assert answer["citations"] == []
    assert answer["answer"] =~ "do not have enough evidence"
  end

  test "source library APIs create, filter, view, and update sources", %{conn: conn} do
    conn = post(conn, ~p"/api/workspaces", %{name: "Source API", root_path: "C:/tmp/api"})
    workspace = json_response(conn, 200)

    conn =
      post(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/text", %{
        title: "Meeting Transcript",
        source_type: "transcript",
        origin: "manual_entry",
        source_date: "2026-05-03",
        text_content: "The rollout risk is unresolved until owners confirm capacity."
      })

    source = json_response(conn, 200)
    assert source["processing_status"] == "ready"

    conn =
      get(
        conn,
        ~p"/api/workspaces/#{workspace["id"]}/sources?processing_status=ready&source_type=transcript"
      )

    assert [%{"id" => source_id}] = json_response(conn, 200)
    assert source_id == source["id"]

    conn = get(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}")
    viewed = json_response(conn, 200)
    assert viewed["text_content"] =~ "rollout risk"
    assert [%{"text" => chunk_text}] = viewed["chunks"]
    assert chunk_text =~ "owners confirm capacity"

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}", %{
        title: "Updated Transcript",
        source_type: "meeting_note",
        source_date: "2026-05-04"
      })

    updated = json_response(conn, 200)
    assert updated["title"] == "Updated Transcript"
    assert updated["source_type"] == "meeting_note"
    assert updated["source_date"] == "2026-05-04"

    conn =
      patch(conn, ~p"/api/workspaces/#{workspace["id"]}/sources/#{source["id"]}/text", %{
        text_content: "The rollout risk now has a named mitigation owner."
      })

    updated_text = json_response(conn, 200)
    assert updated_text["processing_status"] == "ready"
    assert updated_text["text_content"] =~ "named mitigation owner"
  end
end
