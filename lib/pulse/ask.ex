defmodule Pulse.Ask do
  import Ecto.Query

  alias Pulse.Ask.{AnswerCitation, Message, Thread}
  alias Pulse.Intelligence
  alias Pulse.ProjectMemory
  alias Pulse.Repo
  alias Pulse.Sources.Source

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
      memory = ProjectMemory.relevant(workspace_id, context_question)
      evidence_state = classify_evidence(results, memory)
      answer = compose_answer(evidence_state, results, memory)

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
          source_citations(workspace_id, assistant_message.id, evidence_state, results) ++
            project_record_citations(workspace_id, assistant_message.id, memory)

        touch_thread(Repo, thread)

        response(thread, user_message, assistant_message, citations, results)
      end)
    end
  end

  def search(workspace_id, query), do: Intelligence.search(workspace_id, query)

  def get_answer_evidence!(workspace_id, answer_id) do
    message =
      Message
      |> where(
        [m],
        m.workspace_id == ^workspace_id and m.id == ^answer_id and m.role == "assistant"
      )
      |> preload(citations: [:source, :source_passage])
      |> Repo.one!()

    %{
      answer_id: message.id,
      answer: message.content,
      evidence_state: message.evidence_state,
      citations: Enum.map(message.citations, &citation_json/1)
    }
  end

  def compare_sources(workspace_id, source_ids, question) do
    source_ids = Enum.reject(List.wrap(source_ids), &blank?/1)
    question = String.trim(to_string(question || ""))

    cond do
      length(source_ids) < 2 ->
        {:error, :at_least_two_sources_required}

      question == "" ->
        {:error, :blank_question}

      true ->
        sources =
          Source
          |> where([s], s.workspace_id == ^workspace_id and s.id in ^source_ids)
          |> where([s], is_nil(s.deleted_at))
          |> Repo.all()

        cond do
          length(sources) != length(Enum.uniq(source_ids)) ->
            {:error, :source_not_found}

          Enum.any?(sources, &(&1.processing_status != "ready" or blank?(&1.text_content))) ->
            {:error, :source_not_ready}

          true ->
            {:ok, build_comparison(workspace_id, ordered_sources(source_ids, sources), question)}
        end
    end
  end

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

  defp classify_evidence(results, memory) do
    has_memory? = memory.decisions != [] or memory.commitments != []

    cond do
      results == [] and not has_memory? -> "none"
      conflicting?(results) -> "mixed"
      has_memory? -> "strong"
      List.first(results).score >= 4 -> "strong"
      true -> "weak"
    end
  end

  defp compose_answer("none", _results, _memory), do: @no_evidence_answer

  defp compose_answer("weak", results, memory) do
    "The available evidence only partially addresses this. " <>
      memory_summary(memory) <> source_summary("What the sources say: ", results, 2)
  end

  defp compose_answer("mixed", results, memory) do
    "The sources appear to conflict. " <>
      memory_summary(memory) <> source_summary("Conflicting source evidence: ", results, 3)
  end

  defp compose_answer("strong", results, memory) do
    memory = memory_summary(memory)
    source = source_summary("Source evidence says: ", results, 4)

    if memory != "" do
      "Based on approved project memory: " <> memory <> source
    else
      "Based on the available project sources: " <> evidence_summary(results, 4)
    end
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

  defp source_summary(_prefix, [], _limit), do: ""
  defp source_summary(prefix, results, limit), do: prefix <> evidence_summary(results, limit)

  defp memory_summary(%{decisions: decisions, commitments: commitments}) do
    decision_text =
      decisions
      |> Enum.map(&decision_memory_sentence/1)
      |> Enum.reject(&(&1 == ""))

    commitment_text =
      commitments
      |> Enum.map(&commitment_memory_sentence/1)
      |> Enum.reject(&(&1 == ""))

    (decision_text ++ commitment_text)
    |> Enum.join(" ")
    |> then(fn text -> if text == "", do: "", else: text <> " " end)
  end

  defp decision_memory_sentence(decision) do
    base =
      case decision.decision_state do
        "proposed" ->
          "Proposed decision: #{decision.title}."

        "reversed" ->
          "Historical decision reversed: #{decision.title}. #{decision.reversal_reason || ""}"

        "superseded" ->
          replacement =
            if Ecto.assoc_loaded?(decision.superseded_by_decision) and
                 decision.superseded_by_decision do
              " It was superseded by #{decision.superseded_by_decision.title}."
            else
              ""
            end

          "Historical decision superseded: #{decision.title}.#{replacement}"

        _ ->
          "Accepted decision: #{decision.title}."
      end

    rationale =
      if present?(decision.rationale), do: " Rationale: #{decision.rationale}.", else: ""

    tradeoffs =
      if present?(decision.tradeoffs), do: " Tradeoffs: #{decision.tradeoffs}.", else: ""

    base <> rationale <> tradeoffs
  end

  defp commitment_memory_sentence(commitment) do
    due = if commitment.due_date, do: " due #{commitment.due_date}", else: ""

    "Accepted commitment: #{commitment.title}, owned by #{commitment.owner}, status #{commitment.status}#{due}."
  end

  defp citation_results_for("none", _results), do: []
  defp citation_results_for(_state, results), do: Enum.take(results, 4)

  defp source_citations(workspace_id, ask_message_id, evidence_state, results) do
    evidence_state
    |> citation_results_for(results)
    |> Enum.map(fn result ->
      %AnswerCitation{}
      |> AnswerCitation.changeset(%{
        workspace_id: workspace_id,
        ask_message_id: ask_message_id,
        citation_kind: "source_passage",
        source_id: result.source_id,
        source_passage_id: result.source_passage_id,
        evidence_text: excerpt(result.passage_text),
        location_hint: result.location_hint,
        supported_claim: supported_claim(result.passage_text)
      })
      |> Repo.insert!()
      |> Repo.preload([:source, :source_passage])
    end)
  end

  defp project_record_citations(workspace_id, ask_message_id, memory) do
    decision_citations =
      Enum.map(memory.decisions, fn decision ->
        project_record_citation(
          workspace_id,
          ask_message_id,
          "decision",
          decision.id,
          decision_memory_sentence(decision),
          "project memory decision"
        )
      end)

    commitment_citations =
      Enum.map(memory.commitments, fn commitment ->
        project_record_citation(
          workspace_id,
          ask_message_id,
          "commitment",
          commitment.id,
          commitment_memory_sentence(commitment),
          "project memory commitment"
        )
      end)

    decision_citations ++ commitment_citations
  end

  defp project_record_citation(
         workspace_id,
         ask_message_id,
         record_type,
         record_id,
         evidence_text,
         supported_claim
       ) do
    %AnswerCitation{}
    |> AnswerCitation.changeset(%{
      workspace_id: workspace_id,
      ask_message_id: ask_message_id,
      citation_kind: "project_record",
      project_record_type: record_type,
      project_record_id: record_id,
      evidence_text: excerpt(evidence_text),
      location_hint: "approved project record",
      supported_claim: supported_claim
    })
    |> Repo.insert!()
  end

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
    base = %{
      id: citation.id,
      citation_kind: citation.citation_kind,
      supported_claim: citation.supported_claim,
      source_id: citation.source_id,
      source_passage_id: citation.source_passage_id,
      passage_id: citation.source_passage_id,
      chunk_id: citation.source_passage_id,
      source_location: citation.location_hint,
      location_hint: citation.location_hint,
      quote: citation.evidence_text,
      evidence_text: citation.evidence_text,
      project_record_type: citation.project_record_type,
      project_record_id: citation.project_record_id
    }

    if citation.citation_kind == "source_passage" and Ecto.assoc_loaded?(citation.source) and
         citation.source do
      Map.merge(base, %{
        source_title: citation.source.title,
        source_type: citation.source.source_type,
        source_date: citation.source.source_date
      })
    else
      Map.merge(base, %{
        source_title: labelize_record(citation.project_record_type),
        source_type: citation.project_record_type,
        source_date: nil
      })
    end
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

  defp build_comparison(_workspace_id, sources, question) do
    [earlier | _] = sources
    later = List.last(sources)
    earlier_sentences = normalized_sentences(earlier.text_content)
    later_sentences = normalized_sentences(later.text_content)

    added = later_sentences -- earlier_sentences
    removed = earlier_sentences -- later_sentences
    conflicts = conflict_findings(earlier, earlier_sentences, later, later_sentences)

    findings =
      []
      |> add_sentence_findings("added", later, added)
      |> add_sentence_findings("removed", earlier, removed)
      |> Kernel.++(conflicts)
      |> Enum.take(8)

    evidence_state =
      cond do
        findings == [] -> "none"
        Enum.any?(findings, &(&1.finding_type == "conflict")) -> "mixed"
        length(findings) < 2 -> "weak"
        true -> "strong"
      end

    %{
      question: question,
      source_ids: Enum.map(sources, & &1.id),
      evidence_state: evidence_state,
      summary: comparison_summary(evidence_state, earlier, later, findings),
      findings: findings
    }
  end

  defp ordered_sources(source_ids, sources) do
    Enum.map(source_ids, fn id -> Enum.find(sources, &(&1.id == id)) end)
  end

  defp add_sentence_findings(findings, _type, _source, []), do: findings

  defp add_sentence_findings(findings, type, source, sentences) do
    findings ++
      Enum.map(Enum.take(sentences, 3), fn sentence ->
        %{
          finding_type: type,
          summary: sentence,
          evidence_state: "strong",
          evidence: [comparison_evidence(source, sentence)]
        }
      end)
  end

  defp conflict_findings(earlier_source, earlier_sentences, later_source, later_sentences) do
    pairs = [
      {"blocked", "unblocked"},
      {"approved", "rejected"},
      {"resolved", "unresolved"},
      {"high", "low"},
      {"ready", "not ready"},
      {"yes", "no"}
    ]

    for earlier <- earlier_sentences,
        later <- later_sentences,
        {left, right} <- pairs,
        String.contains?(String.downcase(earlier), left) and
          String.contains?(String.downcase(later), right) do
      %{
        finding_type: "conflict",
        summary: "Possible conflict: #{earlier} / #{later}",
        evidence_state: "mixed",
        evidence: [
          comparison_evidence(earlier_source, earlier),
          comparison_evidence(later_source, later)
        ]
      }
    end
  end

  defp comparison_evidence(source, sentence) do
    passage =
      source.workspace_id
      |> Intelligence.list_passages_for_source(source.id)
      |> Enum.find(&String.contains?(&1.text, sentence))

    %{
      source_id: source.id,
      source_passage_id: if(passage, do: passage.id),
      source_title: source.title,
      source_type: source.source_type,
      source_date: source.source_date,
      passage_text: sentence,
      evidence_text: sentence,
      location_hint: if(passage, do: passage.location_hint, else: "source text")
    }
  end

  defp comparison_summary("none", earlier, later, _findings) do
    "Pulse did not find enough comparable evidence between #{earlier.title} and #{later.title}."
  end

  defp comparison_summary(evidence_state, earlier, later, findings) do
    counts = Enum.frequencies_by(findings, & &1.finding_type)

    "Compared #{earlier.title} with #{later.title}. Evidence is #{evidence_state}; " <>
      "found #{Map.get(counts, "added", 0)} added, #{Map.get(counts, "removed", 0)} removed, and #{Map.get(counts, "conflict", 0)} conflicting points."
  end

  defp normalized_sentences(text) do
    text
    |> split_sentences()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 12))
    |> Enum.uniq()
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

  defp supported_claim(text), do: text |> split_sentences() |> List.first()
  defp labelize_record(nil), do: "Project record"
  defp labelize_record(type), do: type |> to_string() |> String.replace("_", " ")
  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
