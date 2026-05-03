defmodule Pulse.Ask.Thread do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  schema "ask_threads" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    has_many :messages, Pulse.Ask.Message, foreign_key: :ask_thread_id

    timestamps()
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:workspace_id, :title])
    |> validate_trimmed_required([:workspace_id])
  end
end
