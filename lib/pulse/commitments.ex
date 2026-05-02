defmodule Pulse.Commitments do
  defdelegate list_commitments(workspace_id, filters \\ %{}), to: Pulse.Records, as: :list
end
