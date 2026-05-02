defmodule Pulse.Workspaces.Workspace do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  schema "workspaces" do
    field :name, :string
    field :root_path, :string

    timestamps()
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :root_path])
    |> validate_trimmed_required([:name, :root_path])
  end
end
