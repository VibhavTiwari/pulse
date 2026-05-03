defmodule Pulse.Decisions do
  import Ecto.Query

  alias Ecto.Multi
  alias Pulse.Decisions.Decision
  alias Pulse.Evidence
  alias Pulse.Intelligence
  alias Pulse.Repo
  alias Pulse.Sources
  alias Pulse.Sources.Source

  @manual_origin "manual"
  @extracted_origin "extracted"
  @decision_signals [
    ~r/\bdecided to\b/i,
    ~r/\bdecision:\b/i,
    ~r/\bagreed to\b/i,
    ~r/\bagreed that\b/i,
    ~r/\bapproved\b/i,
    ~r/\bchose\b/i,
    ~r/\bchosen\b/i,
    ~r/\bselected\b/i,
    ~r/\bwill proceed\b/i,
    ~r/\bplan is\b/i
  ]

  def list_decisions(workspace_id, filters \\ %{}), do: list_accepted(workspace_id, filters)

  def list_accepted(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "accepted", filters)
  end

  def list_suggested(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "suggested", filters)
  end

  def get_decision!(workspace_id, id) do
    Decision
    |> where([d], d.workspace_id == ^workspace_id and d.id == ^id)
    |> Repo.one!()
    |> with_evidence()
  end

  def create_manual_decision(workspace_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "workspace_id" => workspace_id,
        "record_state" => "accepted",
        "source_origin" => @manual_origin
      })
      |> Map.put_new("status", "active")

    evidence_source_id = attrs["evidence_source_id"]
    evidence_text = attrs["evidence_text"]
    location_hint = attrs["location_hint"]

    Multi.new()
    |> Multi.insert(:decision, Decision.changeset(%Decision{}, attrs))
    |> maybe_attach_evidence(workspace_id, evidence_source_id, evidence_text, location_hint)
    |> Repo.transaction()
    |> case do
      {:ok, %{decision: decision}} -> {:ok, with_evidence(decision)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def update_decision(%Decision{} = decision, attrs) do
    decision
    |> Decision.changeset(stringify_keys(attrs))
    |> Repo.update()
    |> case do
      {:ok, decision} -> {:ok, with_evidence(decision)}
      error -> error
    end
  end

  def accept_decision(%Decision{} = decision) do
    cond do
      decision.record_state != "suggested" ->
        {:error, :not_suggested}

      incomplete?(decision) ->
        {:error, :incomplete_decision}

      decision.source_origin == @extracted_origin and evidence_for(decision) == [] ->
        {:error, :missing_evidence}

      true ->
        decision
        |> Decision.changeset(%{"record_state" => "accepted"})
        |> Repo.update()
        |> case do
          {:ok, decision} -> {:ok, with_evidence(decision)}
          error -> error
        end
    end
  end

  def reject_decision(%Decision{} = decision) do
    decision
    |> Decision.changeset(%{"record_state" => "rejected"})
    |> Repo.update()
    |> case do
      {:ok, decision} -> {:ok, with_evidence(decision)}
      error -> error
    end
  end

  def attach_evidence(%Decision{} = decision, attrs) do
    Evidence.create_reference(decision.workspace_id, %{
      "source_id" => attrs["source_id"] || attrs[:source_id],
      "target_entity_type" => "decision",
      "target_entity_id" => decision.id,
      "evidence_text" => attrs["evidence_text"] || attrs[:evidence_text],
      "location_hint" => attrs["location_hint"] || attrs[:location_hint]
    })
  end

  def extract_from_workspace(workspace_id) do
    Source
    |> where(
      [s],
      s.workspace_id == ^workspace_id and s.processing_status == "ready" and is_nil(s.deleted_at)
    )
    |> Repo.all()
    |> Enum.flat_map(fn source ->
      case extract_from_source(source) do
        {:ok, decisions} -> decisions
        {:error, _reason} -> []
      end
    end)
    |> then(&{:ok, &1})
  end

  def extract_from_source_id(workspace_id, source_id) do
    source = Sources.get_source_for_workspace!(workspace_id, source_id)
    extract_from_source(source)
  end

  def extract_from_source(%Source{processing_status: "ready"} = source) do
    suggestions =
      source
      |> candidate_results()
      |> Enum.map(&suggestion_attrs(source, &1))
      |> Enum.reject(&is_nil/1)

    suggestions
    |> Enum.map(&create_extracted_suggestion(source, &1))
    |> collect_results()
  end

  def extract_from_source(%Source{}), do: {:error, :source_not_ready}

  def evidence_for(%Decision{} = decision), do: Evidence.list_for_record("decision", decision.id)

  def with_evidence(%Decision{} = decision) do
    Map.put(decision, :evidence, evidence_for(decision))
  end

  defp list_by_state(workspace_id, state, filters) do
    Decision
    |> where([d], d.workspace_id == ^workspace_id and d.record_state == ^state)
    |> apply_filters(filters)
    |> order_by([d], desc: d.decision_date, desc: d.inserted_at)
    |> Repo.all()
    |> Enum.map(&with_evidence/1)
  end

  defp apply_filters(query, filters) do
    Enum.reduce([:status, :owner], query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [d], field(d, ^field) == ^value)
    end)
  end

  defp maybe_attach_evidence(multi, _workspace_id, nil, _evidence_text, _location_hint), do: multi
  defp maybe_attach_evidence(multi, _workspace_id, "", _evidence_text, _location_hint), do: multi

  defp maybe_attach_evidence(multi, workspace_id, source_id, evidence_text, location_hint) do
    Multi.run(multi, :evidence, fn _repo, %{decision: decision} ->
      Evidence.create_reference(workspace_id, %{
        "source_id" => source_id,
        "target_entity_type" => "decision",
        "target_entity_id" => decision.id,
        "evidence_text" => evidence_text,
        "location_hint" => location_hint
      })
    end)
  end

  defp candidate_results(%Source{} = source) do
    passages = Intelligence.list_passages_for_source(source.workspace_id, source.id)

    if passages == [] do
      case Intelligence.chunk_source(source) do
        {:ok, _passages} -> Intelligence.list_passages_for_source(source.workspace_id, source.id)
        {:error, _reason} -> []
      end
    else
      passages
    end
    |> Enum.flat_map(fn passage ->
      passage.text
      |> split_sentences()
      |> Enum.with_index()
      |> Enum.map(fn {sentence, sentence_index} ->
        %{passage: passage, text: sentence, sentence_index: sentence_index}
      end)
    end)
    |> Enum.filter(&decision_sentence?/1)
  end

  defp suggestion_attrs(source, result) do
    text = String.trim(result.text)

    if String.length(text) < 20 do
      nil
    else
      %{
        "title" => title_from(text),
        "context" => text,
        "decision_date" => source.source_date || Date.utc_today(),
        "owner" => owner_from(text <> " " <> source.text_content),
        "status" => "active",
        "evidence_text" => text,
        "location_hint" =>
          result.passage.location_hint || "passage #{result.passage.passage_index + 1}"
      }
    end
  end

  defp create_extracted_suggestion(%Source{} = source, attrs) do
    Multi.new()
    |> Multi.insert(
      :decision,
      Decision.changeset(%Decision{}, %{
        "workspace_id" => source.workspace_id,
        "title" => attrs["title"],
        "context" => attrs["context"],
        "decision_date" => attrs["decision_date"],
        "owner" => attrs["owner"],
        "status" => attrs["status"],
        "record_state" => "suggested",
        "source_origin" => @extracted_origin
      })
    )
    |> Multi.run(:evidence, fn _repo, %{decision: decision} ->
      Evidence.create_reference(source.workspace_id, %{
        "source_id" => source.id,
        "target_entity_type" => "decision",
        "target_entity_id" => decision.id,
        "evidence_text" => attrs["evidence_text"],
        "location_hint" => attrs["location_hint"]
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{decision: decision}} -> {:ok, with_evidence(decision)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp collect_results(results) do
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, decision} -> decision end)}
    else
      List.first(errors)
    end
  end

  defp incomplete?(%Decision{} = decision) do
    Enum.any?([decision.title, decision.context, decision.owner, decision.status], &blank?/1) or
      is_nil(decision.decision_date) or
      String.downcase(String.trim(decision.owner || "")) == "unknown"
  end

  defp decision_sentence?(%{text: text}) do
    Enum.any?(@decision_signals, &Regex.match?(&1, text)) and not unresolved?(text)
  end

  defp unresolved?(text) do
    Regex.match?(~r/\b(open question|unresolved|discussed|considering|may|might|could)\b/i, text)
  end

  defp split_sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp title_from(text) do
    text
    |> String.replace(
      ~r/^(the team )?(decided to|agreed to|agreed that|approved|chose|selected|decision:)\s+/i,
      ""
    )
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 80)
    |> then(fn title -> if title == "", do: "Extracted decision", else: title end)
  end

  defp owner_from(text) do
    patterns = [
      ~r/\bowner is ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\bowned by ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\b([A-Z][A-Za-z .'-]{1,40}) owns\b/
    ]

    patterns
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, text) do
        [_match, owner] -> owner |> String.trim() |> String.trim_trailing(".")
        _ -> nil
      end
    end)
    |> then(&(&1 || "Unknown"))
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
