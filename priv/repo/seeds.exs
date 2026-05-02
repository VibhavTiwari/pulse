alias Pulse.{Evidence, Records, Repo, Sources, Workspaces}

Repo.delete_all(Pulse.Evidence.EvidenceReference)
Repo.delete_all("brief_meetings")
Repo.delete_all("brief_risks")
Repo.delete_all("brief_commitments")
Repo.delete_all("brief_decisions")
Repo.delete_all("meeting_risks")
Repo.delete_all("meeting_commitments")
Repo.delete_all("meeting_decisions")
Repo.delete_all(Pulse.Briefs.Brief)
Repo.delete_all(Pulse.Meetings.Meeting)
Repo.delete_all(Pulse.Risks.Risk)
Repo.delete_all(Pulse.Commitments.Commitment)
Repo.delete_all(Pulse.Decisions.Decision)
Repo.delete_all(Pulse.Sources.SourceChunk)
Repo.delete_all(Pulse.Sources.Source)
Repo.delete_all(Pulse.Workspaces.Workspace)

{:ok, workspace} =
  Workspaces.create_workspace(%{
    "name" => "Pulse Demo Workspace",
    "root_path" => File.cwd!()
  })

source_bodies = [
  {"Launch Notes", "document", "manual_upload",
   """
   The launch should prioritize a focused private beta before any public announcement. The team decided that the first release will target project leads who already collect decisions and commitments across Slack, meetings, and documents.

   The launch plan should emphasize trust: every AI answer must include citations, and uncited answers should be treated as unsupported. The first public message should avoid broad automation claims until the evidence engine is reliable.
   """},
  {"Evidence Engine Brief", "document", "manual_upload",
   """
   Pulse should use local workspace data as the source of truth. Source ingestion must preserve files, store chunks in PostgreSQL, and return citations that point to source titles and locations.

   The retrieval layer can begin with keyword search as long as the schema is vector-ready. The team agreed to keep extraction deterministic for P0 so demos work without external credentials.
   """},
  {"Meeting Followups", "meeting_note", "manual_upload",
   """
   Rina owns the beta invite list and will prepare the first 20 customer contacts by 2026-05-10.

   Dev owns the local source uploader and will make failed ingestion errors readable by 2026-05-08.

   Maya will draft the daily brief format and include decisions, open commitments, and meeting prep by 2026-05-12.
   """}
]

sources =
  Enum.map(source_bodies, fn {title, source_type, origin, text} ->
    {:ok, source} =
      Sources.create_text_source(workspace.id, %{
        "title" => title,
        "source_type" => source_type,
        "origin" => origin,
        "text_content" => text,
        "metadata" => %{"seed" => true}
      })

    source
  end)

[launch_source, evidence_source, followup_source] = sources

{:ok, private_beta} =
  Records.create("decision", workspace.id, %{
    "title" => "Private beta first",
    "context" => "Launch with a narrow private beta before a public announcement.",
    "decision_date" => "2026-05-02",
    "owner" => "Rina",
    "status" => "active",
    "record_state" => "accepted",
    "source_origin" => "extracted"
  })

{:ok, citations_required} =
  Records.create("decision", workspace.id, %{
    "title" => "Citations required",
    "context" => "AI answers must include source citations to be considered supported.",
    "decision_date" => "2026-05-02",
    "owner" => "Dev",
    "status" => "active",
    "record_state" => "accepted",
    "source_origin" => "extracted"
  })

{:ok, _suggested_decision} =
  Records.create("decision", workspace.id, %{
    "title" => "Keyword retrieval for P0",
    "context" =>
      "Start with deterministic keyword retrieval while keeping the schema vector-ready.",
    "decision_date" => "2026-05-02",
    "owner" => "Dev",
    "status" => "active",
    "record_state" => "suggested",
    "source_origin" => "extracted"
  })

for {decision, source, text} <- [
      {private_beta, launch_source,
       "The launch should prioritize a focused private beta before any public announcement."},
      {citations_required, launch_source,
       "Every AI answer must include citations, and uncited answers should be treated as unsupported."}
    ] do
  {:ok, _} =
    Evidence.create_reference(workspace.id, %{
      "source_id" => source.id,
      "target_entity_type" => "decision",
      "target_entity_id" => decision.id,
      "evidence_text" => text,
      "location_hint" => "seed excerpt"
    })
end

commitments =
  Enum.map(
    [
      {"Rina", "Prepare first 20 beta customer contacts", "2026-05-10", "open"},
      {"Dev", "Make failed ingestion errors readable", "2026-05-08", "open"},
      {"Maya", "Draft daily brief format", "2026-05-12", "open"}
    ],
    fn {owner, title, due_date, status} ->
      {:ok, commitment} =
        Records.create("commitment", workspace.id, %{
          "title" => title,
          "description" => title,
          "owner" => owner,
          "due_date" => due_date,
          "due_date_known" => true,
          "status" => status,
          "record_state" => "accepted",
          "source_origin" => "extracted"
        })

      {:ok, _} =
        Evidence.create_reference(workspace.id, %{
          "source_id" => followup_source.id,
          "target_entity_type" => "commitment",
          "target_entity_id" => commitment.id,
          "evidence_text" => title,
          "location_hint" => "follow-up list"
        })

      commitment
    end
  )

{:ok, launch_risk} =
  Records.create("risk", workspace.id, %{
    "title" => "Unsupported automation claims",
    "description" =>
      "Public messaging could overstate automation before the evidence engine is reliable.",
    "severity" => "high",
    "owner" => "Rina",
    "status" => "open",
    "mitigation" => "Keep launch copy grounded in source-backed outputs.",
    "record_state" => "accepted",
    "source_origin" => "extracted"
  })

{:ok, _} =
  Evidence.create_reference(workspace.id, %{
    "source_id" => launch_source.id,
    "target_entity_type" => "risk",
    "target_entity_id" => launch_risk.id,
    "evidence_text" =>
      "The first public message should avoid broad automation claims until the evidence engine is reliable.",
    "location_hint" => "launch notes"
  })

{:ok, local_demo_risk} =
  Records.create("risk", workspace.id, %{
    "title" => "External credential dependency",
    "description" => "The demo must work without external model or integration credentials.",
    "severity" => "medium",
    "owner" => "Dev",
    "status" => "mitigated",
    "mitigation" => "Use deterministic local retrieval for P0.",
    "record_state" => "accepted",
    "source_origin" => "extracted"
  })

{:ok, _} =
  Evidence.create_reference(workspace.id, %{
    "source_id" => evidence_source.id,
    "target_entity_type" => "risk",
    "target_entity_id" => local_demo_risk.id,
    "evidence_text" => "The team agreed to keep extraction deterministic for P0.",
    "location_hint" => "evidence brief"
  })

{:ok, meeting} =
  Records.create("meeting", workspace.id, %{
    "title" => "Pulse P0 Planning Review",
    "meeting_date" => "2026-05-03",
    "description" =>
      "Confirm private beta scope, review cited Ask AI behavior, and assign remaining source ingestion follow-ups.",
    "attendees" => ["Rina", "Dev", "Maya"]
  })

{:ok, _} = Records.link("meeting", meeting.id, "decision", private_beta.id)
{:ok, _} = Records.link("meeting", meeting.id, "decision", citations_required.id)
{:ok, _} = Records.link("meeting", meeting.id, "commitment", hd(commitments).id)
{:ok, _} = Records.link("meeting", meeting.id, "risk", launch_risk.id)

{:ok, brief} =
  Records.create("brief", workspace.id, %{
    "title" => "Daily Brief",
    "brief_date" => "2026-05-02",
    "brief_type" => "daily",
    "summary" =>
      "Focus today on proving the Postgres-backed evidence loop: sources, accepted project records, risks, and cited answers.",
    "sections" => %{
      "what_changed" => [
        "Private beta and citations are accepted decisions.",
        "Three extracted commitments are ready for follow-up."
      ],
      "needs_attention" => [
        "Unsupported launch claims remain a high-severity open risk.",
        "Source ingestion error handling is still open."
      ]
    }
  })

{:ok, _} = Records.link("brief", brief.id, "decision", private_beta.id)
{:ok, _} = Records.link("brief", brief.id, "decision", citations_required.id)
{:ok, _} = Records.link("brief", brief.id, "commitment", Enum.at(commitments, 1).id)
{:ok, _} = Records.link("brief", brief.id, "risk", launch_risk.id)
{:ok, _} = Records.link("brief", brief.id, "meeting", meeting.id)

{:ok, _} =
  Evidence.create_reference(workspace.id, %{
    "source_id" => launch_source.id,
    "target_entity_type" => "brief",
    "target_entity_id" => brief.id,
    "evidence_text" => "The launch plan should emphasize trust.",
    "location_hint" => "launch notes"
  })
