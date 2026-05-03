defmodule Pulse.Briefs do
  import Ecto.Query

  alias Pulse.Briefs.Brief
  alias Pulse.Commitments
  alias Pulse.Commitments.Commitment
  alias Pulse.Decisions
  alias Pulse.Decisions.Decision
  alias Pulse.Evidence
  alias Pulse.Records
  alias Pulse.Repo
  alias Pulse.Risks.Risk
  alias Pulse.Sources.Source

  @default_window_days 7
  @brief_type "daily"
  @attention_risk_severities ~w(high critical)

  def list_briefs(workspace_id, filters \\ %{}) do
    Brief
    |> where([b], b.workspace_id == ^workspace_id)
    |> apply_filters(filters)
    |> order_by([b], desc: b.brief_date, desc: b.inserted_at)
    |> Repo.all()
  end

  def latest_daily_brief(workspace_id) do
    Brief
    |> where([b], b.workspace_id == ^workspace_id and b.brief_type == @brief_type)
    |> order_by([b], desc: b.brief_date, desc: b.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_brief!(workspace_id, id) do
    Brief
    |> where([b], b.workspace_id == ^workspace_id and b.id == ^id)
    |> Repo.one!()
  end

  def list_item_evidence(workspace_id, brief_id, item_id) do
    brief = get_brief!(workspace_id, brief_id)

    brief.sections
    |> section_items()
    |> Enum.find(&(&1["id"] == item_id))
    |> case do
      nil -> []
      item -> item["evidence_refs"] || []
    end
  end

  def generate_daily_brief(workspace_id, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    brief_date = parse_date(attrs["brief_date"]) || Date.utc_today()
    window_days = parse_window_days(attrs["window_days"])
    window_start = Date.add(brief_date, -(window_days - 1))
    window = %{from: window_start, to: brief_date, days: window_days}

    inputs = generation_inputs(workspace_id, window)
    sections = build_sections(inputs, brief_date)

    attrs = %{
      "workspace_id" => workspace_id,
      "title" => "Daily Brief for #{Date.to_iso8601(brief_date)}",
      "brief_date" => brief_date,
      "brief_type" => @brief_type,
      "summary" => summary_for(inputs, sections, window),
      "sections" => sections
    }

    case Repo.insert(Brief.changeset(%Brief{}, attrs)) do
      {:ok, brief} ->
        link_project_records(brief)
        attach_brief_evidence(brief)
        {:ok, get_brief!(workspace_id, brief.id)}

      error ->
        error
    end
  end

  def generation_inputs(workspace_id, window) do
    %{
      sources: recent_ready_sources(workspace_id, window),
      decisions: recent_decisions(workspace_id, window),
      commitments: Commitments.list_accepted(workspace_id),
      risks: accepted_risks(workspace_id),
      window: window
    }
  end

  defp build_sections(inputs, brief_date) do
    what_changed =
      []
      |> Kernel.++(Enum.map(inputs.decisions, &decision_item/1))
      |> Kernel.++(
        inputs.commitments
        |> Enum.filter(&recent_insert?(&1, inputs.window))
        |> Enum.map(&commitment_change_item/1)
      )
      |> Kernel.++(
        inputs.risks
        |> Enum.filter(&recent_insert_or_update?(&1, inputs.window))
        |> Enum.map(&risk_change_item/1)
      )
      |> Kernel.++(source_update_items(inputs.sources))

    needs_attention =
      []
      |> Kernel.++(attention_commitment_items(inputs.commitments, brief_date))
      |> Kernel.++(attention_risk_items(inputs.risks))

    %{
      "what_changed" =>
        ensure_section(
          "what_changed",
          what_changed,
          "No meaningful changes were found in ready sources or accepted project records."
        ),
      "needs_attention" =>
        ensure_section(
          "needs_attention",
          needs_attention,
          "No overdue commitments, blocked work, active blockers, or high-priority open risks were found."
        )
    }
  end

  defp decision_item(%Decision{} = decision) do
    %{
      "id" => "decision-#{decision.id}",
      "section" => "what_changed",
      "title" => "Decision: #{decision.title}",
      "body" => "Accepted decision owned by #{decision.owner}: #{decision.context}",
      "item_type" => "decision",
      "linked_entity_type" => "decision",
      "linked_entity_id" => decision.id,
      "evidence_state" => evidence_state(decision, "manual accepted decision"),
      "evidence_refs" => evidence_refs(decision)
    }
  end

  defp commitment_change_item(%Commitment{} = commitment) do
    due = if commitment.due_date_known, do: Date.to_iso8601(commitment.due_date), else: "unknown"

    %{
      "id" => "commitment-change-#{commitment.id}",
      "section" => "what_changed",
      "title" => "Commitment: #{commitment.title}",
      "body" =>
        "#{commitment.owner} owns this #{commitment.status} commitment. Due date: #{due}.",
      "item_type" => "commitment",
      "linked_entity_type" => "commitment",
      "linked_entity_id" => commitment.id,
      "evidence_state" => evidence_state(commitment, "manual accepted commitment"),
      "evidence_refs" => evidence_refs(commitment)
    }
  end

  defp risk_change_item(%Risk{} = risk) do
    %{
      "id" => "risk-change-#{risk.id}",
      "section" => "what_changed",
      "title" => "Risk: #{risk.title}",
      "body" =>
        "#{String.capitalize(risk.severity)} #{risk.status} risk owned by #{risk.owner}: #{risk.description}",
      "item_type" => risk_item_type(risk),
      "linked_entity_type" => "risk",
      "linked_entity_id" => risk.id,
      "evidence_state" => evidence_state(risk, "manual accepted risk"),
      "evidence_refs" => evidence_refs(risk)
    }
  end

  defp source_update_items(sources) do
    sources
    |> Enum.take(3)
    |> Enum.map(fn source ->
      %{
        "id" => "source-update-#{source.id}",
        "section" => "what_changed",
        "title" => "New ready source: #{source.title}",
        "body" => excerpt(source.text_content, 240),
        "item_type" => "source_update",
        "linked_entity_type" => "source",
        "linked_entity_id" => source.id,
        "evidence_state" => "strong",
        "evidence_refs" => [source_ref(source, excerpt(source.text_content, 240), "source")]
      }
    end)
  end

  defp attention_commitment_items(commitments, brief_date) do
    commitments
    |> Enum.reject(&(&1.status == "done"))
    |> Enum.filter(fn commitment ->
      commitment.status in ["blocked", "overdue"] or overdue?(commitment, brief_date)
    end)
    |> Enum.map(fn commitment ->
      title =
        cond do
          commitment.status == "blocked" -> "Blocked commitment: #{commitment.title}"
          true -> "Overdue commitment: #{commitment.title}"
        end

      %{
        "id" => "commitment-attention-#{commitment.id}",
        "section" => "needs_attention",
        "title" => title,
        "body" =>
          "#{commitment.owner} owns this #{commitment.status} commitment#{due_phrase(commitment)}.",
        "item_type" => "commitment",
        "linked_entity_type" => "commitment",
        "linked_entity_id" => commitment.id,
        "evidence_state" => evidence_state(commitment, "manual accepted commitment"),
        "evidence_refs" => evidence_refs(commitment)
      }
    end)
  end

  defp attention_risk_items(risks) do
    risks
    |> Enum.filter(fn risk ->
      risk.status == "open" and (risk.severity in @attention_risk_severities or blocker?(risk))
    end)
    |> Enum.map(fn risk ->
      %{
        "id" => "risk-attention-#{risk.id}",
        "section" => "needs_attention",
        "title" => "#{if blocker?(risk), do: "Blocker", else: "Risk"}: #{risk.title}",
        "body" =>
          "#{String.capitalize(risk.severity)} open risk owned by #{risk.owner}: #{risk.description}",
        "item_type" => risk_item_type(risk),
        "linked_entity_type" => "risk",
        "linked_entity_id" => risk.id,
        "evidence_state" => evidence_state(risk, "manual accepted risk"),
        "evidence_refs" => evidence_refs(risk)
      }
    end)
  end

  defp ensure_section(section, [], empty_body) do
    [
      %{
        "id" => "#{section}-empty",
        "section" => section,
        "title" => empty_title(section),
        "body" => empty_body,
        "item_type" => "other",
        "evidence_state" => "none",
        "evidence_refs" => []
      }
    ]
  end

  defp ensure_section(_section, items, _empty_body), do: items

  defp summary_for(inputs, sections, window) do
    change_count = count_claim_items(sections["what_changed"])
    attention_count = count_claim_items(sections["needs_attention"])
    source_count = length(inputs.sources)
    record_count = length(inputs.decisions) + length(inputs.commitments) + length(inputs.risks)

    cond do
      source_count == 0 and record_count == 0 ->
        "No ready sources or accepted project records were available for this daily brief."

      change_count == 0 and attention_count == 0 ->
        "Pulse reviewed #{source_count} ready source#{plural(source_count)} and #{record_count} accepted record#{plural(record_count)} from the #{window.days}-day window and found no project-truth changes or attention items."

      true ->
        "Pulse found #{change_count} change#{plural(change_count)} and #{attention_count} attention item#{plural(attention_count)} from #{source_count} ready source#{plural(source_count)} and accepted project records in the #{window.days}-day window."
    end
  end

  defp recent_ready_sources(workspace_id, window) do
    start_at = start_datetime(window.from)
    end_at = end_datetime(window.to)

    Source
    |> where(
      [s],
      s.workspace_id == ^workspace_id and s.processing_status == "ready" and is_nil(s.deleted_at)
    )
    |> where(
      [s],
      (not is_nil(s.source_date) and s.source_date >= ^window.from and s.source_date <= ^window.to) or
        (is_nil(s.source_date) and s.inserted_at >= ^start_at and s.inserted_at <= ^end_at)
    )
    |> order_by([s], desc: s.source_date, desc: s.inserted_at)
    |> Repo.all()
  end

  defp recent_decisions(workspace_id, window) do
    Decisions.list_accepted(workspace_id)
    |> Enum.filter(&recent_decision?(&1, window))
  end

  defp accepted_risks(workspace_id) do
    Risk
    |> where([r], r.workspace_id == ^workspace_id and r.record_state == "accepted")
    |> order_by([r], desc: r.updated_at, desc: r.inserted_at)
    |> Repo.all()
    |> Enum.map(&with_evidence(&1, "risk"))
  end

  defp apply_filters(query, filters) do
    Enum.reduce([:brief_date, :brief_type], query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [b], field(b, ^field) == ^value)
    end)
  end

  defp link_project_records(%Brief{} = brief) do
    brief.sections
    |> section_items()
    |> Enum.each(fn item ->
      type = item["linked_entity_type"]
      id = item["linked_entity_id"]

      if type in ["decision", "commitment", "risk"] and is_binary(id) do
        Records.link("brief", brief.id, type, id)
      end
    end)
  end

  defp attach_brief_evidence(%Brief{} = brief) do
    brief.sections
    |> section_items()
    |> Enum.flat_map(&(&1["evidence_refs"] || []))
    |> Enum.uniq_by(&{&1["source_id"], &1["evidence_text"], &1["location_hint"]})
    |> Enum.each(fn ref ->
      Evidence.create_reference(brief.workspace_id, %{
        "source_id" => ref["source_id"],
        "target_entity_type" => "brief",
        "target_entity_id" => brief.id,
        "evidence_text" => ref["evidence_text"],
        "location_hint" => ref["location_hint"]
      })
    end)
  end

  defp section_items(sections) do
    (sections["what_changed"] || []) ++ (sections["needs_attention"] || [])
  end

  defp evidence_refs(record) do
    if Map.has_key?(record, :evidence) and is_list(record.evidence) do
      Enum.map(record.evidence, &evidence_ref/1)
    else
      []
    end
  end

  defp evidence_ref(reference) do
    source = if Ecto.assoc_loaded?(reference.source), do: reference.source, else: nil

    %{
      "source_id" => reference.source_id,
      "source_title" => if(source, do: source.title),
      "source_type" => if(source, do: source.source_type),
      "source_date" => if(source && source.source_date, do: Date.to_iso8601(source.source_date)),
      "evidence_text" => reference.evidence_text,
      "location_hint" => reference.location_hint
    }
  end

  defp source_ref(source, text, location_hint) do
    %{
      "source_id" => source.id,
      "source_title" => source.title,
      "source_type" => source.source_type,
      "source_date" => if(source.source_date, do: Date.to_iso8601(source.source_date)),
      "evidence_text" => text,
      "location_hint" => location_hint
    }
  end

  defp evidence_state(record, manual_fallback) do
    refs = evidence_refs(record)

    cond do
      refs != [] -> "strong"
      record.source_origin == "manual" -> "none"
      true -> manual_fallback && "weak"
    end
  end

  defp with_evidence(record, type) do
    Map.put(record, :evidence, Evidence.list_for_record(type, record.id))
  end

  defp recent_decision?(decision, window) do
    if decision.decision_date do
      Date.compare(decision.decision_date, window.from) != :lt and
        Date.compare(decision.decision_date, window.to) != :gt
    else
      recent_insert?(decision, window)
    end
  end

  defp recent_insert?(record, window) do
    date = DateTime.to_date(record.inserted_at)
    Date.compare(date, window.from) != :lt and Date.compare(date, window.to) != :gt
  end

  defp recent_insert_or_update?(record, window) do
    inserted = DateTime.to_date(record.inserted_at)
    updated = DateTime.to_date(record.updated_at)

    Enum.any?([inserted, updated], fn date ->
      Date.compare(date, window.from) != :lt and Date.compare(date, window.to) != :gt
    end)
  end

  defp overdue?(commitment, brief_date) do
    commitment.due_date_known and not is_nil(commitment.due_date) and
      Date.compare(commitment.due_date, brief_date) == :lt
  end

  defp blocker?(risk) do
    text = "#{risk.title} #{risk.description}"
    Regex.match?(~r/\b(blocker|blocked|blocking)\b/i, text)
  end

  defp risk_item_type(risk), do: if(blocker?(risk), do: "blocker", else: "risk")

  defp due_phrase(%Commitment{due_date_known: true, due_date: due_date})
       when not is_nil(due_date) do
    " due #{Date.to_iso8601(due_date)}"
  end

  defp due_phrase(_commitment), do: " with an unknown due date"

  defp count_claim_items(items), do: Enum.count(items, &(&1["item_type"] != "other"))

  defp empty_title("what_changed"), do: "No meaningful changes"
  defp empty_title("needs_attention"), do: "No attention items"

  defp excerpt(nil, _max), do: "Ready source has no readable excerpt."

  defp excerpt(text, max) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max)
    |> then(fn excerpt ->
      if excerpt == "", do: "Ready source has no readable excerpt.", else: excerpt
    end)
  end

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_window_days(value) when is_integer(value) and value > 0, do: min(value, 90)

  defp parse_window_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days > 0 -> min(days, 90)
      _ -> @default_window_days
    end
  end

  defp parse_window_days(_value), do: @default_window_days

  defp start_datetime(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp end_datetime(date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
