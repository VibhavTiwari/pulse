defmodule Pulse.Risks do
  defdelegate list_risks(workspace_id, filters \\ %{}), to: Pulse.Records, as: :list
end
