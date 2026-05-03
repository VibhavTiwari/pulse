defmodule Pulse.Ask do
  import Ecto.Query

  alias Pulse.Ask.{AnswerCitation, Message, Thread}
  alias Pulse.Intelligence
  alias Pulse.Repo

  @model_name "local-evidence-retrieval-v1"
  @no_evidence_answer "I do not have enough evidence in the current project sources to answer that."

  def list_threads(workspace_id) do
    Thread
    |> where([t], t.workspace_id == ^workspace_id)
    |> order_by([t], desc: t.updated_at)
    |> Repo.all()
  end

  def get_thread!(workspace_id, thread_id) do
    thread =
      Thread
      |> where([t], t.workspace_id == ^workspace_id and t.id == ^thread_id)
      |> Repo.one!()

    messages =
      Message
      |> where([m], m.workspace_id == ^workspace_id and m.ask_thread_id == ^thread.id)
      |> order_by([m], asc: m.inserted_at)
      |> preload(citations: [:source, :source_passage])
      |> Repo.all()

    Map.put(thread, :messages, messages)
  end

  def ask(workspace_id, question, opts \\ []) do
    question = String.trim(to_string(question || ""))

    if question == "" do
      {:error, :blank_question}
    else
      thread = get_or_create_thread(workspace_id, opts[:thread_id], question)
      context_question = contextualize_question(thread, question)
      results = Intelligence.search(workspace_id, context_question)
      evidence_state = classify_evidence(results)
      answer = compose_answer(evidence_state, results)

      Repo.transaction(fn ->
        user_message =
          %Message{}
          |> Message.changeset(%{
            workspace_id: workspace_id,
            ask_thread_id: thread.id,
            role: "user",
            content: question
          })
          |> Repo.insert!()

        assistant_message =
          %Message{}
          |> Message.changeset(%{
            workspace_id: workspace_id,
            ask_thread_id: thread.id,
            role: "assistant",
            content: answer,
            evidence_state: evidence_state
          })
          |> Repo.insert!()

        citations =
          evidence_state
          |> citation_results_for(results)
          |> Enum.map(fn result ->
            %AnswerCitation{}
            |> AnswerCitation.changeset(%{
              workspace_id: workspace_id,
              ask_message_id: assistant_message.id,
              source_id: result.source_id,
              source_passage_id: result.source_passage_id,
              evidence_text: excerpt(result.passage_text),
              location_hint: result.location_hint
            })
            |> Repo.insert!()
            |> Repo.preload([:source, :source_passage])
          end)

        touch_thread(Repo, thread)

        response(thread, user_message, assistant_message, citations, results)
      end)
    end
  end

  def search(workspace_id, query), do: Intelligence.search(workspace_id, query)

  defp get_or_create_thread(workspace_id, nil, question) do
    {:ok, thread} =
      %Thread{}
      |> Thread.changeset(%{workspace_id: workspace_id, title: thread_title(question)})
      |> Repo.insert()

    thread
  end

  defp get_or_create_thread(workspace_id, thread_id, _question) do
    Thread
    |> where([t], t.workspace_id == ^workspace_id and t.id == ^thread_id)
    |> Repo.one!()
  end

  defp contextualize_question(%Thread{} = thread, question) do
    prior =
      Message
      |> where([m], m.ask_thread_id == ^thread.id and m.role == "user")
      |> order_by([m], desc: m.inserted_at)
      |> limit(2)
      |> select([m], m.content)
      |> Repo.all()
      |> Enum.reverse()

    Enum.join(prior ++ [question], " ")
  end

  defp classify_evidence([]), do: "none"

  defp classify_evidence(results) do
    cond do
      conflicting?(results) -> "mixed"
      List.first(results).score >= 4 -> "strong"
      true -> "weak"
    end
  end

  defp compose_answer("none", _results), do: @no_evidence_answer

  defp compose_answer("weak", results) do
    "The available sources only partially address this. What they do say: " <>
      evidence_summary(results, 2)
  end

  defp compose_answer("mixed", results) do
    "The sources appear to conflict. " <> evidence_summary(results, 3)
  end

  defp compose_answer("strong", results) do
    "Based on the available project sources: " <> evidence_summary(results, 4)
  end

  defp evidence_summary(results, limit) do
    results
    |> Enum.flat_map(fn result -> split_sentences(result.passage_text) end)
    |> Enum.uniq()
    |> Enum.take(limit)
    |> Enum.join(" ")
  end

  defp split_sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp citation_results_for("none", _results), do: []
  defp citation_results_for(_state, results), do: Enum.take(results, 4)

  defp response(thread, user_message, assistant_message, citations, results) do
    %{
      answer_id: assistant_message.id,
      thread_id: thread.id,
      question_id: user_message.id,
      question: user_message.content,
      answer: assistant_message.content,
      evidence_state: assistant_message.evidence_state,
      model_name: @model_name,
      citations: Enum.map(citations, &citation_json/1),
      search_results: Enum.map(results, &search_result_json/1)
    }
  end

  defp citation_json(%AnswerCitation{} = citation) do
    %{
      id: citation.id,
      source_id: citation.source_id,
      source_passage_id: citation.source_passage_id,
      passage_id: citation.source_passage_id,
      chunk_id: citation.source_passage_id,
      source_title: citation.source.title,
      source_type: citation.source.source_type,
      source_date: citation.source.source_date,
      source_location: citation.location_hint,
      location_hint: citation.location_hint,
      quote: citation.evidence_text,
      evidence_text: citation.evidence_text
    }
  end

  defp search_result_json(result) do
    result
    |> Map.take([
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

  defp excerpt(text) do
    text = String.replace(text, ~r/\s+/, " ")
    if String.length(text) > 280, do: String.slice(text, 0, 279) <> "...", else: text
  end

  defp thread_title(question) do
    question
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 80)
  end

  defp touch_thread(repo, thread) do
    now = DateTime.utc_now(:second)

    repo.update_all(
      from(t in Thread, where: t.id == ^thread.id),
      set: [updated_at: now]
    )
  end

  defp conflicting?(results) do
    text =
      results
      |> Enum.map(&String.downcase(&1.passage_text))
      |> Enum.join(" ")

    Enum.any?([
      has_pair?(text, "blocked", "unblocked"),
      has_pair?(text, "approved", "rejected"),
      has_pair?(text, "resolved", "unresolved"),
      has_pair?(text, "high", "low"),
      has_pair?(text, "ready", "not ready"),
      has_pair?(text, "yes", "no")
    ])
  end

  defp has_pair?(text, left, right) do
    String.contains?(text, left) and String.contains?(text, right)
  end
end
