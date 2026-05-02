defmodule PulseWeb.Api.AskController do
  use PulseWeb, :controller
  alias Pulse.Ask

  def create(conn, %{"workspace_id" => workspace_id, "question" => question}) do
    json(conn, Ask.ask(workspace_id, question))
  end
end
