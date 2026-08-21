defmodule Consigliere.Checkpoints do
  @moduledoc """
  Checkpoint import sequence after process-group death is confirmed.
  Git work runs *outside* any SQLite transaction; only the final SHA
  write goes through DatabaseWriter (docs/architecture/database.md).
  """

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Git

  def import_after_death(attempt_id, opts) do
    if Keyword.fetch!(opts, :process_group) != :dead_verified do
      {:error, {:illegal_transition, %{reason: :death_not_verified}}}
    else
      workspace = Keyword.fetch!(opts, :workspace_path)
      mirror = Keyword.fetch!(opts, :mirror_path)
      sha = Keyword.fetch!(opts, :sha)
      base = Keyword.get(opts, :base_sha)

      with {:ok, sha} <- Git.import_sha(workspace, mirror, sha, base) do
        Attempts.record_checkpointed(attempt_id, Actor.system(), %{
          imported_sha: sha,
          process_group: :dead_verified
        })
      end
    end
  end
end
