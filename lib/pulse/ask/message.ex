defmodule Pulse.Ask.Message do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @roles ~w(user assistant)
  @evidence_states ~w(strong weak none mixed)

  def roles, do: @roles
  def evidence_states, do: @evidence_states

  schema "ask_messages" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    belongs_to :thread, Pulse.Ask.Thread, foreign_key: :ask_thread_id
    field :role, :string
    field :content, :string
    field :evidence_state, :string
    has_many :citations, Pulse.Ask.AnswerCitation, foreign_key: :ask_message_id

    timestamps(updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:workspace_id, :ask_thread_id, :role, :content, :evidence_state])
    |> validate_trimmed_required([:workspace_id, :ask_thread_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_evidence_state()
  end

  defp validate_evidence_state(changeset) do
    role = get_field(changeset, :role)
    evidence_state = get_field(changeset, :evidence_state)

    cond do
      role == "assistant" and is_nil(evidence_state) ->
        add_error(changeset, :evidence_state, "is required for assistant messages")

      role == "assistant" and evidence_state not in @evidence_states ->
        add_error(changeset, :evidence_state, "is invalid")

      role == "user" and not is_nil(evidence_state) ->
        add_error(changeset, :evidence_state, "must be blank for user messages")

      true ->
        changeset
    end
  end
end
