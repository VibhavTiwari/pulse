defmodule PulseWeb.Router do
  use PulseWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PulseWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PulseWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", PulseWeb.Api do
    pipe_through :api

    get "/health", HealthController, :show

    get "/workspaces", WorkspaceController, :index
    post "/workspaces", WorkspaceController, :create
    get "/workspaces/:id", WorkspaceController, :show

    get "/workspaces/:workspace_id/sources", SourceController, :index
    post "/workspaces/:workspace_id/sources", SourceController, :upload
    post "/workspaces/:workspace_id/sources/text", SourceController, :create_text
    get "/workspaces/:workspace_id/sources/:id", SourceController, :show
    patch "/workspaces/:workspace_id/sources/:id", SourceController, :update
    patch "/workspaces/:workspace_id/sources/:id/text", SourceController, :update_text
    delete "/workspaces/:workspace_id/sources/:id", SourceController, :delete
    get "/sources/:source_id/records", EvidenceController, :for_source

    get "/workspaces/:workspace_id/search", AskController, :search
    get "/workspaces/:workspace_id/ask_threads", AskController, :index
    post "/workspaces/:workspace_id/ask_threads", AskController, :start_thread
    get "/workspaces/:workspace_id/ask_threads/:thread_id", AskController, :show
    post "/workspaces/:workspace_id/ask_threads/:thread_id/messages", AskController, :continue
    post "/workspaces/:workspace_id/ask", AskController, :create
    post "/workspaces/:workspace_id/evidence", EvidenceController, :create
    get "/workspaces/:workspace_id/:collection", RecordController, :index
    post "/workspaces/:workspace_id/:collection", RecordController, :create

    get "/evidence/:target_entity_type/:target_entity_id", EvidenceController, :for_record
    delete "/evidence/:id", EvidenceController, :delete

    get "/:type/:id", RecordController, :show
    patch "/:type/:id", RecordController, :update
    post "/:type/:id/accept", RecordController, :accept
    post "/:type/:id/reject", RecordController, :reject
    post "/:parent_type/:parent_id/links/:child_type/:child_id", RecordController, :link
  end
end
