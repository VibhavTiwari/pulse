defmodule Pulse.Workspaces do
  import Ecto.Query

  alias Pulse.Repo
  alias Pulse.Workspaces.Workspace

  def list_workspaces do
    Repo.all(from w in Workspace, order_by: [desc: w.inserted_at])
  end

  def get_workspace!(id), do: Repo.get!(Workspace, id)
  def get_workspace(id), do: Repo.get(Workspace, id)

  def create_workspace(attrs) do
    attrs = Map.put_new(attrs, "root_path", File.cwd!())

    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  def health(%Workspace{} = workspace) do
    %{
      status: "ready",
      source_count: count_for(Pulse.Sources.Source, workspace.id),
      decision_count: count_accepted(Pulse.Decisions.Decision, workspace.id),
      commitment_count: count_accepted(Pulse.Commitments.Commitment, workspace.id),
      risk_count: count_accepted(Pulse.Risks.Risk, workspace.id),
      brief_count: count_for(Pulse.Briefs.Brief, workspace.id)
    }
  end

  defp count_for(schema, workspace_id) do
    Repo.one(from r in schema, where: r.workspace_id == ^workspace_id, select: count(r.id))
  end

  defp count_accepted(schema, workspace_id) do
    Repo.one(
      from r in schema,
        where: r.workspace_id == ^workspace_id and r.record_state == "accepted",
        select: count(r.id)
    )
  end
end
