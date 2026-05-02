defmodule Pulse.Sources do
  import Ecto.Query

  alias Ecto.Multi
  alias Pulse.Repo
  alias Pulse.Sources.{Source, SourceChunk}

  def list_sources(workspace_id, filters \\ %{}) do
    Source
    |> where([s], s.workspace_id == ^workspace_id and is_nil(s.deleted_at))
    |> maybe_filter(
      :processing_status,
      filters["processing_status"] || filters[:processing_status]
    )
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def get_source(id), do: Repo.get(Source, id)

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
    |> Repo.transaction()
    |> case do
      {:ok, %{source: source, chunks: chunks}} -> {:ok, Map.put(source, :chunks, chunks)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def create_uploaded_source(workspace_id, %Plug.Upload{} = upload) do
    body = File.read!(upload.path)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    filename = Path.basename(upload.filename)

    create_text_source(workspace_id, %{
      "title" => Path.rootname(filename),
      "source_type" => upload_type(filename),
      "origin" => "manual_upload",
      "text_content" => body,
      "metadata" => %{"filename" => filename},
      "original_filename" => filename,
      "mime_type" => upload.content_type,
      "content_hash" => hash
    })
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

  defp split_long(text, max_chars) when byte_size(text) <= max_chars, do: [text]
  defp split_long(text, max_chars), do: do_split_long(text, max_chars, [])

  defp do_split_long("", _max_chars, acc), do: Enum.reverse(acc)

  defp do_split_long(text, max_chars, acc) do
    {chunk, rest} = String.split_at(text, max_chars)
    do_split_long(String.trim(rest), max_chars, [chunk | acc])
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp upload_type(filename) do
    case String.downcase(Path.extname(filename)) do
      ".md" -> "document"
      ".txt" -> "note"
      _ -> "document"
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
