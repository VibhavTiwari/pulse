defmodule Pulse.Risks do
  import Ecto.Query

  alias Ecto.Multi
  alias Pulse.Evidence
  alias Pulse.Intelligence
  alias Pulse.Repo
  alias Pulse.Risks.Risk
  alias Pulse.Sources
  alias Pulse.Sources.Source

  @manual_origin "manual"
  @extracted_origin "extracted"
  @risk_signals [
    ~r/\bblocker\b/i,
    ~r/\bblocked\b/i,
    ~r/\bblocking\b/i,
    ~r/\brisk\b/i,
    ~r/\bissue\b/i,
    ~r/\bdelay(?:ed|s)?\b/i,
    ~r/\bslip(?:ped|ping|s)?\b/i,
    ~r/\bconflict\b/i,
    ~r/\bdependency\b/i,
    ~r/\bunresolved\b/i,
    ~r/\bmitigation\b/i,
    ~r/\bcannot proceed\b/i,
    ~r/\bwill not be ready\b/i
  ]

  def list_risks(workspace_id, filters \\ %{}), do: list_accepted(workspace_id, filters)

  def list_accepted(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "accepted", filters)
  end

  def list_suggested(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "suggested", filters)
  end

  def get_risk!(workspace_id, id) do
    Risk
    |> where([r], r.workspace_id == ^workspace_id and r.id == ^id)
    |> Repo.one!()
    |> with_evidence()
  end

  def create_manual_risk(workspace_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "workspace_id" => workspace_id,
        "record_state" => "accepted",
        "source_origin" => @manual_origin
      })
      |> Map.put_new("status", "open")

    evidence_source_id = attrs["evidence_source_id"]
    evidence_text = attrs["evidence_text"]
    location_hint = attrs["location_hint"]

    Multi.new()
    |> Multi.insert(:risk, Risk.changeset(%Risk{}, attrs))
    |> maybe_attach_evidence(workspace_id, evidence_source_id, evidence_text, location_hint)
    |> Repo.transaction()
    |> case do
      {:ok, %{risk: risk}} -> {:ok, with_evidence(risk)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def update_risk(%Risk{} = risk, attrs) do
    risk
    |> Risk.changeset(stringify_keys(attrs))
    |> Repo.update()
    |> case do
      {:ok, risk} -> {:ok, with_evidence(risk)}
      error -> error
    end
  end

  def update_status(%Risk{} = risk, status), do: update_risk(risk, %{"status" => status})

  def accept_risk(%Risk{} = risk) do
    cond do
      risk.record_state != "suggested" ->
        {:error, :not_suggested}

      incomplete?(risk) ->
        {:error, :incomplete_risk}

      risk.source_origin == @extracted_origin and evidence_for(risk) == [] ->
        {:error, :missing_evidence}

      true ->
        risk
        |> Risk.changeset(%{"record_state" => "accepted"})
        |> Repo.update()
        |> case do
          {:ok, risk} -> {:ok, with_evidence(risk)}
          error -> error
        end
    end
  end

  def reject_risk(%Risk{} = risk) do
    risk
    |> Risk.changeset(%{"record_state" => "rejected"})
    |> Repo.update()
    |> case do
      {:ok, risk} -> {:ok, with_evidence(risk)}
      error -> error
    end
  end

  def attach_evidence(%Risk{} = risk, attrs) do
    Evidence.create_reference(risk.workspace_id, %{
      "source_id" => attrs["source_id"] || attrs[:source_id],
      "target_entity_type" => "risk",
      "target_entity_id" => risk.id,
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
        {:ok, risks} -> risks
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
      |> Enum.map(&suggestion_attrs(&1))
      |> Enum.reject(&is_nil/1)

    suggestions
    |> Enum.map(&create_extracted_suggestion(source, &1))
    |> collect_results()
  end

  def extract_from_source(%Source{}), do: {:error, :source_not_ready}

  def evidence_for(%Risk{} = risk), do: Evidence.list_for_record("risk", risk.id)

  def with_evidence(%Risk{} = risk) do
    Map.put(risk, :evidence, evidence_for(risk))
  end

  defp list_by_state(workspace_id, state, filters) do
    Risk
    |> where([r], r.workspace_id == ^workspace_id and r.record_state == ^state)
    |> apply_filters(filters)
    |> order_by([r], desc: r.severity, desc: r.inserted_at)
    |> Repo.all()
    |> Enum.map(&with_evidence/1)
  end

  defp apply_filters(query, filters) do
    Enum.reduce([:severity, :status, :owner], query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [r], field(r, ^field) == ^value)
    end)
  end

  defp maybe_attach_evidence(multi, _workspace_id, nil, _evidence_text, _location_hint), do: multi
  defp maybe_attach_evidence(multi, _workspace_id, "", _evidence_text, _location_hint), do: multi

  defp maybe_attach_evidence(multi, workspace_id, source_id, evidence_text, location_hint) do
    Multi.run(multi, :evidence, fn _repo, %{risk: risk} ->
      Evidence.create_reference(workspace_id, %{
        "source_id" => source_id,
        "target_entity_type" => "risk",
        "target_entity_id" => risk.id,
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
    |> Enum.filter(&risk_sentence?/1)
  end

  defp suggestion_attrs(result) do
    text = String.trim(result.text)

    cond do
      String.length(text) < 20 ->
        nil

      vague?(text) ->
        nil

      true ->
        %{
          "title" => title_from(text),
          "description" => text,
          "severity" => severity_from(text),
          "owner" => owner_from(text),
          "status" => status_from(text),
          "mitigation" => mitigation_from(text),
          "evidence_text" => text,
          "location_hint" =>
            result.passage.location_hint || "passage #{result.passage.passage_index + 1}"
        }
    end
  end

  defp create_extracted_suggestion(%Source{} = source, attrs) do
    Multi.new()
    |> Multi.insert(
      :risk,
      Risk.changeset(%Risk{}, %{
        "workspace_id" => source.workspace_id,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "severity" => attrs["severity"],
        "owner" => attrs["owner"],
        "status" => attrs["status"],
        "mitigation" => attrs["mitigation"],
        "record_state" => "suggested",
        "source_origin" => @extracted_origin
      })
    )
    |> Multi.run(:evidence, fn _repo, %{risk: risk} ->
      Evidence.create_reference(source.workspace_id, %{
        "source_id" => source.id,
        "target_entity_type" => "risk",
        "target_entity_id" => risk.id,
        "evidence_text" => attrs["evidence_text"],
        "location_hint" => attrs["location_hint"]
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{risk: risk}} -> {:ok, with_evidence(risk)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp collect_results(results) do
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, risk} -> risk end)}
    else
      List.first(errors)
    end
  end

  defp incomplete?(%Risk{} = risk) do
    Enum.any?([risk.title, risk.description, risk.severity, risk.owner, risk.status], &blank?/1) or
      String.downcase(String.trim(risk.owner || "")) == "unknown"
  end

  defp risk_sentence?(%{text: text}) do
    Enum.any?(@risk_signals, &Regex.match?(&1, text)) and not vague?(text)
  end

  defp vague?(text) do
    Regex.match?(
      ~r/\b(may|might|could|maybe|brainstorm|hypothetical|possible concern|normal uncertainty)\b/i,
      text
    ) and
      not Regex.match?(~r/\b(blocked|blocker|delay|conflict|risk|issue|cannot proceed)\b/i, text)
  end

  defp split_sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp title_from(text) do
    text
    |> String.replace(~r/^(risk:|issue:|blocker:)\s*/i, "")
    |> String.replace(~r/\b(owner is|owned by|mitigation is)\b.*$/i, "")
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 90)
    |> then(fn title -> if title == "", do: "Extracted risk", else: title end)
  end

  defp severity_from(text) do
    lower = String.downcase(text)

    cond do
      Regex.match?(~r/\b(critical|severe|cannot proceed|blocking launch|blocked launch)\b/, lower) ->
        "critical"

      Regex.match?(~r/\b(high|blocker|blocked|delay|slipping|conflict)\b/, lower) ->
        "high"

      Regex.match?(~r/\b(medium|moderate|dependency|unresolved)\b/, lower) ->
        "medium"

      true ->
        "low"
    end
  end

  defp status_from(text) do
    lower = String.downcase(text)

    cond do
      Regex.match?(~r/\b(resolved|closed|no longer blocked)\b/, lower) -> "resolved"
      Regex.match?(~r/\b(mitigated|mitigation in place|workaround)\b/, lower) -> "mitigated"
      true -> "open"
    end
  end

  defp owner_from(text) do
    patterns = [
      ~r/\bowner is ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\bowned by ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\bassigned to ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\b([A-Z][A-Za-z .'-]{1,40}) owns\b/
    ]

    patterns
    |> Enum.find_value(fn pattern ->
      case Regex.run(pattern, text) do
        [_match, owner] -> owner |> String.trim() |> clean_owner()
        _ -> nil
      end
    end)
    |> then(&(&1 || "Unknown"))
  end

  defp clean_owner(owner) do
    owner
    |> String.replace(~r/\b(and|because|by|on|before|due|to)\b.*$/i, "")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp mitigation_from(text) do
    case Regex.run(~r/\bmitigation(?: is|:)?\s+(.+)$/i, text) do
      [_match, mitigation] -> mitigation |> String.trim() |> String.trim_trailing(".")
      _ -> nil
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
