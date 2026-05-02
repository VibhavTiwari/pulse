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
    assert [_citation] = answer["citations"]
  end
end
