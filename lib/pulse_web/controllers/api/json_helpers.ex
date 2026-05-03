defmodule PulseWeb.Api.JSONHelpers do
  def workspace(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      root_path: workspace.root_path,
      health: Pulse.Workspaces.health(workspace),
      created_at: workspace.inserted_at,
      updated_at: workspace.updated_at
    }
  end

  def source(source) do
    base = %{
      id: source.id,
      workspace_id: source.workspace_id,
      title: source.title,
      source_type: source.source_type,
      origin: source.origin,
      source_date: source.source_date,
      text_content: source.text_content,
      metadata: source.metadata || %{},
      processing_status: source.processing_status,
      status: source.processing_status,
      original_filename: source.original_filename,
      mime_type: source.mime_type,
      content_hash: source.content_hash,
      error_message: source.error_message,
      created_at: source.inserted_at,
      updated_at: source.updated_at
    }

    if Map.has_key?(source, :chunks) do
      Map.put(base, :chunks, Enum.map(source.chunks, &chunk/1))
    else
      base
    end
  end

  def chunk(chunk) do
    %{
      id: chunk.id,
      source_id: chunk.source_id,
      workspace_id: chunk.workspace_id,
      chunk_index: chunk.chunk_index,
      text: chunk.text,
      metadata: chunk.metadata || %{},
      created_at: chunk.inserted_at
    }
  end

  def search_result(result) do
    Map.take(result, [
      :passage_id,
      :source_passage_id,
      :source_id,
      :source_title,
      :source_type,
      :source_date,
      :passage_text,
      :location_hint,
      :rank,
      :score
    ])
  end

  def ask_thread(thread) do
    base = %{
      id: thread.id,
      workspace_id: thread.workspace_id,
      title: thread.title,
      created_at: thread.inserted_at,
      updated_at: thread.updated_at
    }

    if Map.has_key?(thread, :messages) and is_list(thread.messages) do
      Map.put(base, :messages, Enum.map(thread.messages, &ask_message/1))
    else
      base
    end
  end

  def ask_message(message) do
    base = %{
      id: message.id,
      workspace_id: message.workspace_id,
      ask_thread_id: message.ask_thread_id,
      role: message.role,
      content: message.content,
      evidence_state: message.evidence_state,
      created_at: message.inserted_at
    }

    if Ecto.assoc_loaded?(message.citations) do
      Map.put(base, :citations, Enum.map(message.citations, &answer_citation/1))
    else
      base
    end
  end

  def answer_citation(citation) do
    %{
      id: citation.id,
      workspace_id: citation.workspace_id,
      ask_message_id: citation.ask_message_id,
      source_id: citation.source_id,
      source_passage_id: citation.source_passage_id,
      source_title: if(Ecto.assoc_loaded?(citation.source), do: citation.source.title, else: nil),
      source_type:
        if(Ecto.assoc_loaded?(citation.source), do: citation.source.source_type, else: nil),
      source_date:
        if(Ecto.assoc_loaded?(citation.source), do: citation.source.source_date, else: nil),
      evidence_text: citation.evidence_text,
      quote: citation.evidence_text,
      location_hint: citation.location_hint,
      source_location: citation.location_hint,
      created_at: citation.inserted_at
    }
  end

  def record(record, type) do
    base =
      record
      |> Map.from_struct()
      |> Map.drop([:__meta__, :workspace, :source])
      |> Map.drop([:decisions, :commitments, :risks, :meetings])

    base
    |> maybe_put_assoc(record, type, :decisions)
    |> maybe_put_assoc(record, type, :commitments)
    |> maybe_put_assoc(record, type, :risks)
    |> maybe_put_assoc(record, type, :meetings)
  end

  def decision(decision) do
    %{
      id: decision.id,
      workspace_id: decision.workspace_id,
      title: decision.title,
      context: decision.context,
      decision_date: decision.decision_date,
      owner: decision.owner,
      status: decision.status,
      record_state: decision.record_state,
      source_origin: decision.source_origin,
      evidence_count: evidence_count(decision),
      evidence: decision_evidence(decision),
      created_at: decision.inserted_at,
      updated_at: decision.updated_at
    }
  end

  def evidence(reference) do
    %{
      id: reference.id,
      workspace_id: reference.workspace_id,
      source_id: reference.source_id,
      source_title:
        if(Ecto.assoc_loaded?(reference.source), do: reference.source.title, else: nil),
      target_entity_type: reference.target_entity_type,
      target_entity_id: reference.target_entity_id,
      evidence_text: reference.evidence_text,
      location_hint: reference.location_hint,
      created_at: reference.inserted_at
    }
  end

  defp decision_evidence(decision) do
    if Map.has_key?(decision, :evidence) and is_list(decision.evidence) do
      Enum.map(decision.evidence, &evidence/1)
    else
      []
    end
  end

  defp evidence_count(decision), do: length(decision_evidence(decision))

  def errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp maybe_put_assoc(map, record, _type, assoc) do
    value = Map.get(record, assoc)

    if is_list(value) and Ecto.assoc_loaded?(value) do
      Map.put(map, assoc, Enum.map(value, &record(&1, singular(assoc))))
    else
      map
    end
  end

  defp singular(:decisions), do: "decision"
  defp singular(:commitments), do: "commitment"
  defp singular(:risks), do: "risk"
  defp singular(:meetings), do: "meeting"
end
