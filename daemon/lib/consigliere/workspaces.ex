defmodule Consigliere.Workspaces do
  @moduledoc false

  alias Consigliere.Workspaces.Transitions

  defdelegate create(mission_id, actor, attrs), to: Transitions
  defdelegate mark_daemon_exclusive(workspace_id, actor, opts), to: Transitions
  defdelegate quarantine(workspace_id, actor, reason), to: Transitions
  defdelegate release(workspace_id, actor), to: Transitions
end
