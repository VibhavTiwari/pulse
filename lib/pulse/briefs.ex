defmodule Pulse.Briefs do
  defdelegate list_briefs(workspace_id, filters \\ %{}), to: Pulse.Records, as: :list
end
