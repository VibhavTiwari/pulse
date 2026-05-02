defmodule Pulse.Evidence do
  import Ecto.Query

  alias Pulse.Evidence.EvidenceReference
  alias Pulse.Repo
  alias Pulse.Sources
  alias Pulse.Records

  def create_reference(workspace_id, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    source_id = attrs["source_id"]
    target_type = attrs["target_entity_type"]
    target_id = attrs["target_entity_id"]

    with {:source, source} when not is_nil(source) <- {:source, Sources.get_source(source_id)},
         true <- source.workspace_id == workspace_id || {:error, :source_workspace_mismatch},
         {:target, target} when not is_nil(target) <-
           {:target, Records.get(target_type, target_id)},
         true <- target.workspace_id == workspace_id || {:error, :target_workspace_mismatch} do
      %EvidenceReference{}
      |> EvidenceReference.changeset(Map.put(attrs, "workspace_id", workspace_id))
      |> Repo.insert()
    else
      {:source, nil} -> {:error, :source_not_found}
      {:target, nil} -> {:error, :target_not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, :workspace_mismatch}
    end
  end

  def list_for_record(target_type, target_id) do
    EvidenceReference
    |> where([e], e.target_entity_type == ^target_type and e.target_entity_id == ^target_id)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
    |> Repo.preload(:source)
  end

  def list_for_source(source_id) do
    Repo.all(
      from e in EvidenceReference,
        where: e.source_id == ^source_id,
        order_by: [desc: e.inserted_at]
    )
  end

  def delete_reference(id) do
    case Repo.get(EvidenceReference, id) do
      nil -> {:error, :not_found}
      reference -> Repo.delete(reference)
    end
  end
end
