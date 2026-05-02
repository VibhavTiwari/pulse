defmodule Pulse.Meetings do
  defdelegate list_meetings(workspace_id, filters \\ %{}), to: Pulse.Records, as: :list
end
