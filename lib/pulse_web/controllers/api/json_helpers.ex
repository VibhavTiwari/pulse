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
