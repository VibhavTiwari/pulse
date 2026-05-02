defmodule PulseWeb.PageController do
  use PulseWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
