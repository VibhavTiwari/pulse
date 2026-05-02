defmodule Pulse.Decisions do
  defdelegate list_decisions(workspace_id, filters \\ %{}), to: Pulse.Records, as: :list
end
