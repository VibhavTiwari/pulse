defmodule PulseWeb.Api.AskController do
  use PulseWeb, :controller
  alias Pulse.Ask
  alias PulseWeb.Api.JSONHelpers

  def index(conn, %{"workspace_id" => workspace_id}) do
    json(conn, Enum.map(Ask.list_threads(workspace_id), &JSONHelpers.ask_thread/1))
  end

  def start_thread(conn, %{"workspace_id" => workspace_id} = params) do
    create(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def show(conn, %{"workspace_id" => workspace_id, "thread_id" => thread_id}) do
    json(conn, JSONHelpers.ask_thread(Ask.get_thread!(workspace_id, thread_id)))
  end

  def create(conn, %{"workspace_id" => workspace_id, "question" => question}) do
    case Ask.ask(workspace_id, question, thread_id: nil) do
      {:ok, answer} ->
        json(conn, answer)

      {:error, :blank_question} ->
        conn |> put_status(:bad_request) |> json(%{errors: %{question: ["can't be blank"]}})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{errors: %{question: ["is required"]}})
  end

  def continue(conn, %{
        "workspace_id" => workspace_id,
        "thread_id" => thread_id,
        "question" => question
      }) do
    case Ask.ask(workspace_id, question, thread_id: thread_id) do
      {:ok, answer} ->
        json(conn, answer)

      {:error, :blank_question} ->
        conn |> put_status(:bad_request) |> json(%{errors: %{question: ["can't be blank"]}})
    end
  end

  def continue(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{errors: %{question: ["is required"]}})
  end

  def search(conn, %{"workspace_id" => workspace_id, "q" => query}) do
    json(conn, Enum.map(Ask.search(workspace_id, query), &JSONHelpers.search_result/1))
  end
end
