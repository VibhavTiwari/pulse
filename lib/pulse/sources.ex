defmodule Pulse.Sources do
  import Ecto.Query

  alias Ecto.Multi
  alias Pulse.Intelligence
  alias Pulse.Repo
  alias Pulse.Sources.{Source, SourceChunk, SourceDuplicateFlag}

  @stale_after_days 180

  def list_sources(workspace_id, filters \\ %{}) do
    Source
    |> where([s], s.workspace_id == ^workspace_id and is_nil(s.deleted_at))
    |> maybe_filter(
      :processing_status,
      filters["processing_status"] || filters[:processing_status]
    )
    |> maybe_filter(:source_type, filters["source_type"] || filters[:source_type])
    |> maybe_filter(
      :classified_source_type,
      filters["classified_source_type"] || filters[:classified_source_type]
    )
    |> maybe_filter(:quality_label, filters["quality_label"] || filters[:quality_label])
    |> maybe_filter_quality_reason(filters["quality_reason"] || filters[:quality_reason])
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
    |> preload_p1()
  end

  def get_source(id), do: Repo.get(Source, id)

  def get_source_for_workspace(workspace_id, id) do
    Source
    |> where([s], s.workspace_id == ^workspace_id and s.id == ^id and is_nil(s.deleted_at))
    |> Repo.one()
    |> preload_p1()
  end

  def get_source_for_workspace!(workspace_id, id) do
    Source
    |> where([s], s.workspace_id == ^workspace_id and s.id == ^id and is_nil(s.deleted_at))
    |> Repo.one!()
    |> preload_p1()
  end

  def get_source!(id) do
    Source
    |> Repo.get!(id)
    |> Repo.preload(:workspace)
  end

  def get_source_with_chunks!(id) do
    source = Repo.get!(Source, id)
    chunks = Repo.all(from c in SourceChunk, where: c.source_id == ^id, order_by: c.chunk_index)
    Map.put(source, :chunks, chunks)
  end

  def get_source_with_chunks_for_workspace!(workspace_id, id) do
    source = get_source_for_workspace!(workspace_id, id)
    chunks = Repo.all(from c in SourceChunk, where: c.source_id == ^id, order_by: c.chunk_index)
    Map.put(source, :chunks, chunks)
  end

  def create_text_source(workspace_id, attrs) do
    text = attrs["text_content"] || attrs[:text_content] || ""

    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{"workspace_id" => workspace_id, "processing_status" => "ready"})

    chunks = chunk_text(text)

    Multi.new()
    |> Multi.insert(:source, Source.changeset(%Source{}, attrs))
    |> Multi.run(:chunks, fn repo, %{source: source} ->
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        %SourceChunk{}
        |> SourceChunk.changeset(%{
          workspace_id: workspace_id,
          source_id: source.id,
          chunk_index: index,
          text: chunk,
          metadata: %{"source_location" => "chunk #{index + 1}"}
        })
        |> repo.insert!()
      end)
      |> then(&{:ok, &1})
    end)
    |> Multi.run(:passages, fn repo, %{source: source} ->
      {:ok, Intelligence.replace_source_passages(repo, source)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{source: source, chunks: chunks}} ->
        source = enrich_source!(source)
        {:ok, Map.put(source, :chunks, chunks)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def create_uploaded_source(workspace_id, %Plug.Upload{} = upload, attrs \\ %{}) do
    attrs = attrs |> stringify_keys() |> Map.drop(["file"])
    filename = Path.basename(upload.filename)

    body = File.read!(upload.path)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    source_attrs =
      attrs
      |> Map.put_new("title", Path.rootname(filename))
      |> Map.put_new("source_type", upload_type(filename))
      |> Map.merge(%{
        "workspace_id" => workspace_id,
        "origin" => "manual_upload",
        "processing_status" => "pending",
        "metadata" => Map.merge(attrs["metadata"] || %{}, %{"filename" => filename}),
        "original_filename" => filename,
        "mime_type" => upload.content_type,
        "content_hash" => hash
      })

    with {:ok, source} <- Repo.insert(Source.changeset(%Source{}, source_attrs)) do
      case extract_text(filename, body) do
        {:ok, text} ->
          update_source_text(source, text)

        {:error, reason} ->
          mark_processing_status(source, "failed", reason)
      end
    end
  end

  def update_source_metadata(%Source{} = source, attrs) do
    source
    |> Source.metadata_changeset(stringify_keys(attrs))
    |> Repo.update()
    |> enrich_result()
  end

  def update_source_text(%Source{} = source, text) do
    attrs = %{
      "text_content" => text,
      "processing_status" => "ready",
      "error_message" => nil
    }

    chunks = chunk_text(text || "")

    Multi.new()
    |> Multi.update(:source, Source.text_changeset(source, attrs))
    |> Multi.delete_all(:old_chunks, from(c in SourceChunk, where: c.source_id == ^source.id))
    |> Multi.run(:chunks, fn repo, %{source: source} ->
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        %SourceChunk{}
        |> SourceChunk.changeset(%{
          workspace_id: source.workspace_id,
          source_id: source.id,
          chunk_index: index,
          text: chunk,
          metadata: %{"source_location" => "chunk #{index + 1}"}
        })
        |> repo.insert!()
      end)
      |> then(&{:ok, &1})
    end)
    |> Multi.run(:passages, fn repo, %{source: source} ->
      {:ok, Intelligence.replace_source_passages(repo, source)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{source: source, chunks: chunks}} ->
        source = enrich_source!(source)
        {:ok, Map.put(source, :chunks, chunks)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def mark_processing_status(%Source{} = source, status, error_message \\ nil) do
    attrs = %{
      "processing_status" => status,
      "error_message" => error_message,
      "text_content" => source.text_content
    }

    Multi.new()
    |> Multi.update(:source, Source.status_changeset(source, attrs))
    |> Multi.run(:passages, fn repo, %{source: source} ->
      {:ok, Intelligence.replace_source_passages(repo, source)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{source: source}} -> {:ok, enrich_source!(source)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def update_source_classification(%Source{} = source, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(["classified_source_type"])
      |> Map.merge(%{
        "classification_confidence" => "manual",
        "classification_method" => "manual"
      })

    source
    |> Source.classification_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, source} -> {:ok, preload_p1(source)}
      error -> error
    end
  end

  def reclassify_source(%Source{} = source) do
    source
    |> apply_classification(force?: false)
    |> case do
      {:ok, source} -> {:ok, preload_p1(source)}
      error -> error
    end
  end

  def assess_source_quality(%Source{} = source) do
    source
    |> apply_quality()
    |> case do
      {:ok, source} -> {:ok, preload_p1(source)}
      error -> error
    end
  end

  def list_timeline(workspace_id, filters \\ %{}) do
    workspace_id
    |> list_sources(filters)
    |> Enum.sort_by(&timeline_sort/1, {:desc, Date})
    |> Enum.map(&timeline_item/1)
  end

  def list_duplicate_flags(workspace_id, filters \\ %{}) do
    SourceDuplicateFlag
    |> where([f], f.workspace_id == ^workspace_id)
    |> maybe_filter(:resolution_state, filters["resolution_state"] || filters[:resolution_state])
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
    |> Repo.preload([:source, :matched_source])
  end

  def detect_duplicates(%Source{} = source) do
    source = Repo.preload(source, [:duplicate_flags])

    Source
    |> where([candidate], candidate.workspace_id == ^source.workspace_id)
    |> where([candidate], candidate.id != ^source.id and is_nil(candidate.deleted_at))
    |> Repo.all()
    |> Enum.reduce({:ok, []}, fn
      candidate, {:ok, flags} ->
        case duplicate_signal(source, candidate) do
          nil ->
            {:ok, flags}

          attrs ->
            case upsert_duplicate_flag(source, candidate, attrs) do
              {:ok, flag} -> {:ok, [flag | flags]}
              {:error, changeset} -> {:error, changeset}
            end
        end

      _candidate, error ->
        error
    end)
    |> case do
      {:ok, flags} -> {:ok, Enum.reverse(flags)}
      error -> error
    end
  end

  def resolve_duplicate_flag(workspace_id, flag_id, resolution_state)
      when resolution_state in ["confirmed_duplicate", "dismissed"] do
    flag =
      SourceDuplicateFlag
      |> where([f], f.workspace_id == ^workspace_id and f.id == ^flag_id)
      |> Repo.one!()

    flag
    |> SourceDuplicateFlag.resolution_changeset(%{resolution_state: resolution_state})
    |> Repo.update()
    |> case do
      {:ok, flag} -> {:ok, Repo.preload(flag, [:source, :matched_source])}
      error -> error
    end
  end

  def delete_source(%Source{} = source) do
    source
    |> Source.changeset(%{"deleted_at" => DateTime.utc_now(:second)})
    |> Repo.update()
  end

  def chunk_text(text, max_chars \\ 900) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.flat_map(&split_long(&1, max_chars))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def timeline_item(%Source{} = source) do
    {timeline_date, basis} = timeline_date(source)

    %{
      source: source,
      timeline_date: timeline_date,
      timeline_date_basis: basis,
      duplicate_count: unresolved_duplicate_count(source)
    }
  end

  defp split_long(text, max_chars) when byte_size(text) <= max_chars, do: [text]
  defp split_long(text, max_chars), do: do_split_long(text, max_chars, [])

  defp do_split_long("", _max_chars, acc), do: Enum.reverse(acc)

  defp do_split_long(text, max_chars, acc) do
    {chunk, rest} = String.split_at(text, max_chars)
    do_split_long(String.trim(rest), max_chars, [chunk | acc])
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp maybe_filter_quality_reason(query, nil), do: query
  defp maybe_filter_quality_reason(query, ""), do: query

  defp maybe_filter_quality_reason(query, reason),
    do: where(query, [s], ^reason in s.quality_reasons)

  defp preload_p1(nil), do: nil

  defp preload_p1(sources) when is_list(sources),
    do: Repo.preload(sources, duplicate_flags: :matched_source)

  defp preload_p1(source), do: Repo.preload(source, duplicate_flags: :matched_source)

  defp enrich_result({:ok, source}), do: {:ok, enrich_source!(source)}
  defp enrich_result(error), do: error

  defp enrich_source!(%Source{} = source) do
    {:ok, source} = apply_classification(source, force?: false)
    {:ok, source} = apply_quality(source)
    {:ok, _flags} = detect_duplicates(source)
    preload_p1(source)
  end

  defp apply_classification(%Source{} = source, opts) do
    if source.classification_method == "manual" and not Keyword.get(opts, :force?, false) do
      {:ok, source}
    else
      do_apply_classification(source)
    end
  end

  defp do_apply_classification(source) do
    source
    |> Source.enrichment_changeset(classification_attrs(source))
    |> Repo.update()
  end

  defp classification_attrs(source) do
    {type, confidence, method} = classify(source)

    %{
      classified_source_type: type,
      classification_confidence: confidence,
      classification_method: method
    }
  end

  defp classify(source) do
    explicit =
      case source.source_type do
        "meeting_note" -> {"meeting", "high"}
        "project_update" -> {"update", "high"}
        "transcript" -> {"transcript", "high"}
        "document" -> {"document", "medium"}
        _ -> nil
      end

    text_available? = source.processing_status == "ready" and present?(source.text_content)
    haystack = normalized_text([source.title, source.original_filename, source.text_content])

    inferred =
      cond do
        contains_any?(haystack, ~w(transcript speaker attendee said discussion)) ->
          {"transcript", if(text_available?, do: "high", else: "medium")}

        contains_any?(haystack, [
          "status update",
          "weekly update",
          "project update",
          "progress update"
        ]) ->
          {"update", if(text_available?, do: "high", else: "medium")}

        contains_any?(haystack, ~w(plan roadmap strategy milestones timeline sequencing launch)) ->
          {"plan", if(text_available?, do: "high", else: "medium")}

        contains_any?(haystack, ["meeting notes", "standup", "sync", "retro", "agenda"]) ->
          {"meeting", if(text_available?, do: "high", else: "medium")}

        true ->
          nil
      end

    {type, confidence} = inferred || explicit || {"document", "low"}
    method = if text_available?, do: "text_based", else: "metadata_only"
    {type, confidence, method}
  end

  defp apply_quality(%Source{} = source) do
    source
    |> Source.enrichment_changeset(quality_attrs(source))
    |> Repo.update()
  end

  defp quality_attrs(%Source{processing_status: "pending"}) do
    %{
      quality_label: "unknown",
      quality_reasons: [],
      quality_assessed_at: DateTime.utc_now(:second)
    }
  end

  defp quality_attrs(%Source{processing_status: "failed"}) do
    %{
      quality_label: "poor",
      quality_reasons: ["unclear"],
      quality_assessed_at: DateTime.utc_now(:second)
    }
  end

  defp quality_attrs(source) do
    text = source.text_content || ""
    word_count = text |> String.split(~r/\s+/, trim: true) |> length()

    reasons =
      []
      |> maybe_add_reason(word_count < 12, "thin")
      |> maybe_add_reason(stale?(source), "stale")
      |> maybe_add_reason(unclear?(text), "unclear")

    label =
      cond do
        "unclear" in reasons and "thin" in reasons -> "poor"
        "thin" in reasons -> "weak"
        length(reasons) >= 2 -> "weak"
        reasons != [] -> "usable"
        word_count >= 40 -> "strong"
        true -> "usable"
      end

    %{
      quality_label: label,
      quality_reasons: reasons,
      quality_assessed_at: DateTime.utc_now(:second)
    }
  end

  defp duplicate_signal(source, candidate) do
    source_text = normalized_text(source.text_content || "")
    candidate_text = normalized_text(candidate.text_content || "")
    source_title = normalized_text(source.title || "")
    candidate_title = normalized_text(candidate.title || "")

    cond do
      present?(source.content_hash) and source.content_hash == candidate.content_hash ->
        %{
          duplicate_type: "exact_duplicate",
          confidence: "high",
          reason: "Uploaded file content hash matches #{candidate.title}."
        }

      present?(source_text) and source_text == candidate_text ->
        %{
          duplicate_type: "exact_duplicate",
          confidence: "high",
          reason: "Readable text is effectively identical to #{candidate.title}."
        }

      text_similarity(source_text, candidate_text) >= 0.72 ->
        %{
          duplicate_type: "near_duplicate",
          confidence: "medium",
          reason: "Readable text substantially overlaps with #{candidate.title}."
        }

      text_similarity(source_title, candidate_title) >= 0.66 ->
        %{
          duplicate_type: "possible_duplicate",
          confidence: "low",
          reason: "Source title is similar to #{candidate.title}."
        }

      true ->
        nil
    end
  end

  defp upsert_duplicate_flag(source, candidate, attrs) do
    attrs =
      attrs
      |> Map.put(:workspace_id, source.workspace_id)
      |> Map.put(:source_id, source.id)
      |> Map.put(:matched_source_id, candidate.id)
      |> Map.put(:resolution_state, "unresolved")

    existing =
      Repo.one(
        from f in SourceDuplicateFlag,
          where: f.source_id == ^source.id and f.matched_source_id == ^candidate.id
      )

    (existing || %SourceDuplicateFlag{})
    |> SourceDuplicateFlag.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, flag} -> {:ok, Repo.preload(flag, [:source, :matched_source])}
      error -> error
    end
  end

  defp unresolved_duplicate_count(source) do
    flags = if Ecto.assoc_loaded?(source.duplicate_flags), do: source.duplicate_flags, else: []
    Enum.count(flags, &(&1.resolution_state == "unresolved"))
  end

  defp timeline_sort(source) do
    {date, _basis} = timeline_date(source)
    date
  end

  defp timeline_date(source) do
    if source.source_date do
      {source.source_date, "source_date"}
    else
      {DateTime.to_date(source.inserted_at), "created_at"}
    end
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp stale?(%Source{source_date: nil}), do: false

  defp stale?(%Source{source_date: source_date}) do
    Date.diff(Date.utc_today(), source_date) > @stale_after_days
  end

  defp unclear?(text) do
    trimmed = String.trim(text || "")

    trimmed == "" or
      String.contains?(trimmed, ["???", "[inaudible]", "unclear", "unknown"]) or
      String.length(String.replace(trimmed, ~r/[[:alnum:]\s.,;:!?-]/u, "")) > 8
  end

  defp text_similarity("", _candidate), do: 0.0
  defp text_similarity(_source, ""), do: 0.0

  defp text_similarity(left, right) do
    left_tokens = token_set(left)
    right_tokens = token_set(right)
    union_size = MapSet.union(left_tokens, right_tokens) |> MapSet.size()

    if union_size == 0 do
      0.0
    else
      MapSet.intersection(left_tokens, right_tokens) |> MapSet.size() |> Kernel./(union_size)
    end
  end

  defp token_set(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp normalized_text(values) when is_list(values),
    do: values |> Enum.join(" ") |> normalized_text()

  defp normalized_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp contains_any?(haystack, needles), do: Enum.any?(needles, &String.contains?(haystack, &1))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp upload_type(filename) do
    case String.downcase(Path.extname(filename)) do
      ".md" -> "document"
      ".txt" -> "note"
      _ -> "document"
    end
  end

  defp extract_text(filename, body) do
    case String.downcase(Path.extname(filename)) do
      ext when ext in [".txt", ".md"] ->
        cond do
          not String.valid?(body) ->
            {:error, "Only UTF-8 text files can be read in P0."}

          String.trim(body) == "" ->
            {:error, "No readable text was found in the uploaded file."}

          true ->
            {:ok, body}
        end

      _ ->
        {:error, "Unsupported upload format. P0 supports readable .txt and .md files only."}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
