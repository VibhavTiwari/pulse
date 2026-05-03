defmodule Pulse.Commitments do
  import Ecto.Query

  alias Ecto.Multi
  alias Pulse.Commitments.Commitment
  alias Pulse.Evidence
  alias Pulse.Intelligence
  alias Pulse.Repo
  alias Pulse.Sources
  alias Pulse.Sources.Source

  @manual_origin "manual"
  @extracted_origin "extracted"
  @commitment_signals [
    ~r/\baction item:\b/i,
    ~r/\bnext step:\b/i,
    ~r/\bcommitted to\b/i,
    ~r/\bagreed to\b/i,
    ~r/\bwill\b/i,
    ~r/\bto follow up\b/i,
    ~r/\bassigned to\b/i,
    ~r/\bowner is\b/i,
    ~r/\bowns\b/i
  ]

  def list_commitments(workspace_id, filters \\ %{}), do: list_accepted(workspace_id, filters)

  def list_accepted(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "accepted", filters)
  end

  def list_suggested(workspace_id, filters \\ %{}) do
    list_by_state(workspace_id, "suggested", filters)
  end

  def get_commitment!(workspace_id, id) do
    Commitment
    |> where([c], c.workspace_id == ^workspace_id and c.id == ^id)
    |> Repo.one!()
    |> with_evidence()
  end

  def create_manual_commitment(workspace_id, attrs) do
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
    |> Multi.insert(:commitment, Commitment.changeset(%Commitment{}, attrs))
    |> maybe_attach_evidence(workspace_id, evidence_source_id, evidence_text, location_hint)
    |> Repo.transaction()
    |> case do
      {:ok, %{commitment: commitment}} -> {:ok, with_evidence(commitment)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def update_commitment(%Commitment{} = commitment, attrs) do
    commitment
    |> Commitment.changeset(stringify_keys(attrs))
    |> Repo.update()
    |> case do
      {:ok, commitment} -> {:ok, with_evidence(commitment)}
      error -> error
    end
  end

  def update_status(%Commitment{} = commitment, status) do
    update_commitment(commitment, %{"status" => status})
  end

  def accept_commitment(%Commitment{} = commitment) do
    cond do
      commitment.record_state != "suggested" ->
        {:error, :not_suggested}

      incomplete?(commitment) ->
        {:error, :incomplete_commitment}

      commitment.source_origin == @extracted_origin and evidence_for(commitment) == [] ->
        {:error, :missing_evidence}

      true ->
        commitment
        |> Commitment.changeset(%{"record_state" => "accepted"})
        |> Repo.update()
        |> case do
          {:ok, commitment} -> {:ok, with_evidence(commitment)}
          error -> error
        end
    end
  end

  def reject_commitment(%Commitment{} = commitment) do
    commitment
    |> Commitment.changeset(%{"record_state" => "rejected"})
    |> Repo.update()
    |> case do
      {:ok, commitment} -> {:ok, with_evidence(commitment)}
      error -> error
    end
  end

  def attach_evidence(%Commitment{} = commitment, attrs) do
    Evidence.create_reference(commitment.workspace_id, %{
      "source_id" => attrs["source_id"] || attrs[:source_id],
      "target_entity_type" => "commitment",
      "target_entity_id" => commitment.id,
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
        {:ok, commitments} -> commitments
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

  def evidence_for(%Commitment{} = commitment),
    do: Evidence.list_for_record("commitment", commitment.id)

  def with_evidence(%Commitment{} = commitment) do
    Map.put(commitment, :evidence, evidence_for(commitment))
  end

  defp list_by_state(workspace_id, state, filters) do
    Commitment
    |> where([c], c.workspace_id == ^workspace_id and c.record_state == ^state)
    |> apply_filters(filters)
    |> order_by([c], asc: c.due_date, desc: c.inserted_at)
    |> Repo.all()
    |> Enum.map(&with_evidence/1)
  end

  defp apply_filters(query, filters) do
    Enum.reduce([:status, :owner, :due_date], query, fn field, acc ->
      value = filters[to_string(field)] || filters[field]
      if is_nil(value) or value == "", do: acc, else: where(acc, [c], field(c, ^field) == ^value)
    end)
  end

  defp maybe_attach_evidence(multi, _workspace_id, nil, _evidence_text, _location_hint), do: multi
  defp maybe_attach_evidence(multi, _workspace_id, "", _evidence_text, _location_hint), do: multi

  defp maybe_attach_evidence(multi, workspace_id, source_id, evidence_text, location_hint) do
    Multi.run(multi, :evidence, fn _repo, %{commitment: commitment} ->
      Evidence.create_reference(workspace_id, %{
        "source_id" => source_id,
        "target_entity_type" => "commitment",
        "target_entity_id" => commitment.id,
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
    |> Enum.filter(&commitment_sentence?/1)
  end

  defp suggestion_attrs(_source, result) do
    text = String.trim(result.text)
    owner = owner_from(text)

    cond do
      String.length(text) < 20 ->
        nil

      owner == "Unknown" and not Regex.match?(~r/\b(owner is|assigned to|owns)\b/i, text) ->
        nil

      true ->
        due_date = due_date_from(text)

        %{
          "title" => title_from(text),
          "description" => text,
          "owner" => owner,
          "due_date" => due_date,
          "due_date_known" => not is_nil(due_date),
          "status" => status_from(text),
          "evidence_text" => text,
          "location_hint" =>
            result.passage.location_hint || "passage #{result.passage.passage_index + 1}"
        }
    end
  end

  defp create_extracted_suggestion(%Source{} = source, attrs) do
    Multi.new()
    |> Multi.insert(
      :commitment,
      Commitment.changeset(%Commitment{}, %{
        "workspace_id" => source.workspace_id,
        "title" => attrs["title"],
        "description" => attrs["description"],
        "owner" => attrs["owner"],
        "due_date" => attrs["due_date"],
        "due_date_known" => attrs["due_date_known"],
        "status" => attrs["status"],
        "record_state" => "suggested",
        "source_origin" => @extracted_origin
      })
    )
    |> Multi.run(:evidence, fn _repo, %{commitment: commitment} ->
      Evidence.create_reference(source.workspace_id, %{
        "source_id" => source.id,
        "target_entity_type" => "commitment",
        "target_entity_id" => commitment.id,
        "evidence_text" => attrs["evidence_text"],
        "location_hint" => attrs["location_hint"]
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{commitment: commitment}} -> {:ok, with_evidence(commitment)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp collect_results(results) do
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, commitment} -> commitment end)}
    else
      List.first(errors)
    end
  end

  defp incomplete?(%Commitment{} = commitment) do
    Enum.any?([commitment.title, commitment.owner, commitment.status], &blank?/1) or
      String.downcase(String.trim(commitment.owner || "")) == "unknown" or
      (commitment.due_date_known == true and is_nil(commitment.due_date))
  end

  defp commitment_sentence?(%{text: text}) do
    Enum.any?(@commitment_signals, &Regex.match?(&1, text)) and not unresolved?(text)
  end

  defp unresolved?(text) do
    Regex.match?(
      ~r/\b(open question|unresolved|discussed|considering|may|might|could|maybe)\b/i,
      text
    )
  end

  defp split_sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp title_from(text) do
    text
    |> String.replace(~r/^(action item:|next step:)\s*/i, "")
    |> String.replace(~r/\b(owner is|owned by|assigned to)\b.*$/i, "")
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 90)
    |> then(fn title -> if title == "", do: "Extracted commitment", else: title end)
  end

  defp owner_from(text) do
    patterns = [
      ~r/\bowner is ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\bowned by ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\bassigned to ([A-Z][A-Za-z .'-]{1,40})/i,
      ~r/\b([A-Z][A-Za-z .'-]{1,40}) committed to\b/,
      ~r/\b([A-Z][A-Za-z .'-]{1,40}) will\b/,
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
    |> String.replace(~r/\b(by|on|before|due|to)\b.*$/i, "")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp due_date_from(text) do
    cond do
      match = Regex.run(~r/\b(?:by|due|before)\s+(\d{4}-\d{2}-\d{2})\b/i, text) ->
        parse_date(Enum.at(match, 1))

      match = Regex.run(~r/\b(?:by|due|before)\s+([A-Z][a-z]+ \d{1,2}, \d{4})\b/, text) ->
        parse_us_date(Enum.at(match, 1))

      true ->
        nil
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_us_date(value) do
    with [month, day, year] <- String.split(value, ~r/[\s,]+/, trim: true),
         {:ok, month} <- month_number(month),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(year, month, day) do
      date
    else
      _ -> nil
    end
  end

  defp month_number(month) do
    months = %{
      "january" => 1,
      "february" => 2,
      "march" => 3,
      "april" => 4,
      "may" => 5,
      "june" => 6,
      "july" => 7,
      "august" => 8,
      "september" => 9,
      "october" => 10,
      "november" => 11,
      "december" => 12
    }

    case Map.fetch(months, String.downcase(month)) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp status_from(text) do
    lower = String.downcase(text)

    cond do
      String.contains?(lower, "blocked") -> "blocked"
      String.contains?(lower, "done") or String.contains?(lower, "completed") -> "done"
      overdue?(due_date_from(text)) -> "overdue"
      true -> "open"
    end
  end

  defp overdue?(nil), do: false
  defp overdue?(date), do: Date.compare(date, Date.utc_today()) == :lt

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
