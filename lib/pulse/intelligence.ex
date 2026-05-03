defmodule Pulse.Intelligence do
  import Ecto.Query

  alias Pulse.Intelligence.SourcePassage
  alias Pulse.Repo
  alias Pulse.Sources
  alias Pulse.Sources.Source

  @max_results 4
  @stopwords ~w(
    a an and are as at be been but by can did do does for from have how i in is it its
    me my of on or our should that the their this to was we were what when where which
    who why with you your
  )

  def list_passages_for_source(workspace_id, source_id) do
    SourcePassage
    |> where([p], p.workspace_id == ^workspace_id and p.source_id == ^source_id)
    |> order_by([p], asc: p.passage_index)
    |> Repo.all()
  end

  def chunk_source(%Source{processing_status: "ready", text_content: text} = source)
      when is_binary(text) do
    if String.trim(text) == "" do
      {:error, :source_not_ready}
    else
      Repo.transaction(fn -> replace_source_passages(Repo, source) end)
    end
  end

  def chunk_source(%Source{}), do: {:error, :source_not_ready}

  def replace_source_passages(repo, %Source{} = source) do
    if source.processing_status == "ready" and present?(source.text_content) do
      chunks = Sources.chunk_text(source.text_content)

      repo.delete_all(from p in SourcePassage, where: p.source_id == ^source.id)

      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        %SourcePassage{}
        |> SourcePassage.changeset(%{
          workspace_id: source.workspace_id,
          source_id: source.id,
          passage_index: index,
          text: chunk,
          location_hint: "passage #{index + 1}",
          metadata: %{"chunker" => "paragraph_max_900_v1"}
        })
        |> repo.insert!()
      end)
    else
      repo.delete_all(from p in SourcePassage, where: p.source_id == ^source.id)
      []
    end
  end

  def ensure_workspace_indexed(workspace_id) do
    Source
    |> where(
      [s],
      s.workspace_id == ^workspace_id and s.processing_status == "ready" and
        not is_nil(s.text_content) and is_nil(s.deleted_at)
    )
    |> Repo.all()
    |> Enum.each(fn source ->
      exists? =
        Repo.exists?(
          from p in SourcePassage,
            where: p.workspace_id == ^workspace_id and p.source_id == ^source.id
        )

      unless exists?, do: chunk_source(source)
    end)
  end

  def search(workspace_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_results)
    tokens = tokenize(query)

    if tokens == [] do
      []
    else
      ensure_workspace_indexed(workspace_id)

      SourcePassage
      |> join(:inner, [p], s in Source, on: s.id == p.source_id)
      |> where(
        [p, s],
        p.workspace_id == ^workspace_id and s.processing_status == "ready" and
          is_nil(s.deleted_at)
      )
      |> preload([p, s], source: s)
      |> Repo.all()
      |> Enum.map(&score_result(&1, tokens))
      |> Enum.filter(fn result -> result.score > 0 end)
      |> Enum.sort_by(fn result -> {-result.score, result.rank_seed} end)
      |> Enum.take(limit)
      |> Enum.with_index(1)
      |> Enum.map(fn {result, rank} -> %{result | rank: rank} end)
    end
  end

  def tokenize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.uniq()
  end

  defp score_result(%SourcePassage{} = passage, tokens) do
    lower = String.downcase(passage.text)
    source_title = String.downcase(passage.source.title || "")

    token_hits =
      Enum.reduce(tokens, 0, fn token, acc ->
        cond do
          String.contains?(lower, token) -> acc + 2
          String.contains?(source_title, token) -> acc + 1
          true -> acc
        end
      end)

    %{
      passage_id: passage.id,
      source_passage_id: passage.id,
      source_id: passage.source_id,
      source_title: passage.source.title,
      source_type: passage.source.source_type,
      source_date: passage.source.source_date,
      passage_text: passage.text,
      location_hint: passage.location_hint || "passage #{passage.passage_index + 1}",
      rank: nil,
      score: token_hits,
      rank_seed: passage.passage_index,
      passage: passage
    }
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
