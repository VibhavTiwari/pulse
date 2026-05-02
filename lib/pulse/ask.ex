defmodule Pulse.Ask do
  import Ecto.Query

  alias Pulse.Repo
  alias Pulse.Sources.{Source, SourceChunk}

  @model_name "local-keyword-evidence-v0"
  @fallback "I do not have enough information in this workspace to answer that."

  def ask(workspace_id, question) do
    chunks = search_chunks(workspace_id, question)

    if chunks == [] do
      %{
        answer_id: Ecto.UUID.generate(),
        question: question,
        answer: @fallback,
        model_name: @model_name,
        citations: []
      }
    else
      answer_id = Ecto.UUID.generate()

      %{
        answer_id: answer_id,
        question: question,
        answer: compose_answer(chunks),
        model_name: @model_name,
        citations:
          Enum.map(chunks, fn chunk ->
            %{
              source_id: chunk.source_id,
              chunk_id: chunk.id,
              source_title: chunk.source.title,
              quote: excerpt(chunk.text),
              source_location: "chunk #{chunk.chunk_index + 1}"
            }
          end)
      }
    end
  end

  defp search_chunks(workspace_id, question) do
    tokens = tokenize(question)

    SourceChunk
    |> join(:inner, [c], s in Source, on: s.id == c.source_id)
    |> where(
      [c, s],
      c.workspace_id == ^workspace_id and s.processing_status == "ready" and is_nil(s.deleted_at)
    )
    |> preload([c, s], source: s)
    |> Repo.all()
    |> Enum.map(&{score(&1.text, tokens), &1})
    |> Enum.filter(fn {score, _chunk} -> score > 0 end)
    |> Enum.sort_by(fn {score, _chunk} -> -score end)
    |> Enum.take(3)
    |> Enum.map(fn {_score, chunk} -> chunk end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in ~w(the and for with what about that have from this into)))
  end

  defp score(text, tokens) do
    lower = String.downcase(text)
    Enum.count(tokens, &String.contains?(lower, &1))
  end

  defp compose_answer(chunks) do
    chunks
    |> Enum.flat_map(fn chunk -> String.split(chunk.text, ~r/(?<=[.!?])\s+/, trim: true) end)
    |> Enum.filter(&(String.length(&1) > 40))
    |> Enum.take(4)
    |> Enum.join(" ")
  end

  defp excerpt(text) do
    text = String.replace(text, ~r/\s+/, " ")
    if String.length(text) > 260, do: String.slice(text, 0, 259) <> "...", else: text
  end
end
