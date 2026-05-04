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
    get "/workspaces/:workspace_id/sources/timeline", SourceController, :timeline
    get "/workspaces/:workspace_id/sources/duplicates", SourceController, :duplicate_flags
    post "/workspaces/:workspace_id/sources", SourceController, :upload
    post "/workspaces/:workspace_id/sources/text", SourceController, :create_text
    get "/workspaces/:workspace_id/sources/:id", SourceController, :show
    patch "/workspaces/:workspace_id/sources/:id", SourceController, :update
    patch "/workspaces/:workspace_id/sources/:id/text", SourceController, :update_text

    patch "/workspaces/:workspace_id/sources/:id/classification",
          SourceController,
          :update_classification

    post "/workspaces/:workspace_id/sources/:id/detect_duplicates",
         SourceController,
         :detect_duplicates

    post "/workspaces/:workspace_id/sources/:id/reassess_quality",
         SourceController,
         :reassess_quality

    get "/workspaces/:workspace_id/source_duplicate_flags/:flag_id",
        SourceController,
        :show_duplicate_flag

    post "/workspaces/:workspace_id/source_duplicate_flags/:flag_id/confirm",
         SourceController,
         :confirm_duplicate

    post "/workspaces/:workspace_id/source_duplicate_flags/:flag_id/dismiss",
         SourceController,
         :dismiss_duplicate

    delete "/workspaces/:workspace_id/sources/:id", SourceController, :delete
    get "/sources/:source_id/records", EvidenceController, :for_source

    get "/workspaces/:workspace_id/dashboard", DashboardController, :show

    get "/workspaces/:workspace_id/search", AskController, :search
    get "/workspaces/:workspace_id/ask_threads", AskController, :index
    post "/workspaces/:workspace_id/ask_threads", AskController, :start_thread
    get "/workspaces/:workspace_id/ask_threads/:thread_id", AskController, :show
    post "/workspaces/:workspace_id/ask_threads/:thread_id/messages", AskController, :continue
    post "/workspaces/:workspace_id/ask", AskController, :create
    get "/workspaces/:workspace_id/ask_answers/:answer_id/evidence", AskController, :evidence
    post "/workspaces/:workspace_id/ask/compare_sources", AskController, :compare
    get "/workspaces/:workspace_id/decisions", DecisionController, :index
    post "/workspaces/:workspace_id/decisions", DecisionController, :create
    post "/workspaces/:workspace_id/decisions/extract", DecisionController, :extract
    get "/workspaces/:workspace_id/decision_suggestions", DecisionController, :suggestions
    get "/workspaces/:workspace_id/decisions/:id", DecisionController, :show
    patch "/workspaces/:workspace_id/decisions/:id", DecisionController, :update
    patch "/workspaces/:workspace_id/decisions/:id/lifecycle", DecisionController, :lifecycle
    post "/workspaces/:workspace_id/decisions/:id/reverse", DecisionController, :reverse
    post "/workspaces/:workspace_id/decisions/:id/supersede", DecisionController, :supersede
    post "/workspaces/:workspace_id/decisions/:id/accept", DecisionController, :accept
    post "/workspaces/:workspace_id/decisions/:id/reject", DecisionController, :reject
    post "/workspaces/:workspace_id/decisions/:id/evidence", DecisionController, :attach_evidence
    get "/workspaces/:workspace_id/commitments", CommitmentController, :index
    post "/workspaces/:workspace_id/commitments", CommitmentController, :create
    post "/workspaces/:workspace_id/commitments/extract", CommitmentController, :extract
    get "/workspaces/:workspace_id/commitment_suggestions", CommitmentController, :suggestions
    get "/workspaces/:workspace_id/commitments/:id", CommitmentController, :show
    patch "/workspaces/:workspace_id/commitments/:id", CommitmentController, :update
    patch "/workspaces/:workspace_id/commitments/:id/status", CommitmentController, :update_status
    post "/workspaces/:workspace_id/commitments/:id/accept", CommitmentController, :accept
    post "/workspaces/:workspace_id/commitments/:id/reject", CommitmentController, :reject

    post "/workspaces/:workspace_id/commitments/:id/evidence",
         CommitmentController,
         :attach_evidence

    get "/workspaces/:workspace_id/risks", RiskController, :index
    post "/workspaces/:workspace_id/risks", RiskController, :create
    post "/workspaces/:workspace_id/risks/extract", RiskController, :extract
    get "/workspaces/:workspace_id/risk_suggestions", RiskController, :suggestions
    get "/workspaces/:workspace_id/risks/:id", RiskController, :show
    patch "/workspaces/:workspace_id/risks/:id", RiskController, :update
    patch "/workspaces/:workspace_id/risks/:id/status", RiskController, :update_status
    post "/workspaces/:workspace_id/risks/:id/accept", RiskController, :accept
    post "/workspaces/:workspace_id/risks/:id/reject", RiskController, :reject
    post "/workspaces/:workspace_id/risks/:id/evidence", RiskController, :attach_evidence

    get "/workspaces/:workspace_id/review_inbox", ReviewInboxController, :index
    get "/workspaces/:workspace_id/review_inbox/:type/:id", ReviewInboxController, :show
    patch "/workspaces/:workspace_id/review_inbox/:type/:id", ReviewInboxController, :update

    post "/workspaces/:workspace_id/review_inbox/:type/:id/accept",
         ReviewInboxController,
         :accept

    post "/workspaces/:workspace_id/review_inbox/:type/:id/reject",
         ReviewInboxController,
         :reject

    get "/workspaces/:workspace_id/briefs", BriefController, :index
    get "/workspaces/:workspace_id/briefs/latest", BriefController, :latest
    post "/workspaces/:workspace_id/briefs/daily", BriefController, :generate
    get "/workspaces/:workspace_id/briefs/:id", BriefController, :show

    get "/workspaces/:workspace_id/briefs/:id/items/:item_id/evidence",
        BriefController,
        :item_evidence

    get "/workspaces/:workspace_id/meetings", MeetingController, :index
    post "/workspaces/:workspace_id/meetings", MeetingController, :create
    get "/workspaces/:workspace_id/meetings/:id", MeetingController, :show
    patch "/workspaces/:workspace_id/meetings/:id", MeetingController, :update
    get "/workspaces/:workspace_id/meetings/:id/prep", MeetingController, :prep
    post "/workspaces/:workspace_id/meetings/:id/prep/refresh", MeetingController, :refresh_prep

    post "/workspaces/:workspace_id/meetings/:id/decisions/:decision_id",
         MeetingController,
         :link_decision

    delete "/workspaces/:workspace_id/meetings/:id/decisions/:decision_id",
           MeetingController,
           :unlink_decision

    post "/workspaces/:workspace_id/meetings/:id/commitments/:commitment_id",
         MeetingController,
         :link_commitment

    delete "/workspaces/:workspace_id/meetings/:id/commitments/:commitment_id",
           MeetingController,
           :unlink_commitment

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
