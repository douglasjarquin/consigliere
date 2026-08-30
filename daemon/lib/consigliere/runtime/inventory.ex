defmodule Consigliere.Runtime.Inventory do
  @moduledoc """
  Canonical runtime-manifest verifier. A PID/PGID is signalable only
  from a live inventory record whose path, Attempt, Mission, and fence
  all match.
  """

  alias Consigliere.Attempts.Attempt
  alias Consigliere.Home
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Runtime.ProcessIdentity
  alias Consigliere.V0.Limits

  @live ~w(starting running terminating)
  @dead ~w(dead_verified dead_unverified)

  def signalable?({:valid_live, manifest, _attempt}) do
    pgid = manifest["pgid"]
    is_integer(pgid) and pgid > 1
  end

  def signalable?(_), do: false

  def verify(path, home) do
    with :ok <- canonical_path(path, home),
         {:ok, manifest} <- read_manifest(path),
         :ok <- schema(manifest),
         :ok <- path_identity(path, manifest),
         :ok <- safe_pgid(manifest),
         :ok <- socket_path(manifest, home),
         {:ok, attempt} <- matching_attempt(manifest) do
      classify(manifest, attempt)
    else
      {:error, :enoent} -> :missing
      {:error, :identity} -> :identity_mismatch
      {:error, :stale} -> :stale_generation
      {:error, :unsafe_pgid} -> :unsafe_pgid
      {:error, :corrupt} -> :corrupt
    end
  end

  def liveness(manifest) when is_map(manifest) do
    with :ok <- safe_pgid(manifest),
         {:ok, group_state} <- group_liveness(manifest),
         {:ok, runner_state} <- runner_identity(manifest),
         {:ok, harness_state} <- harness_identity(manifest) do
      case {group_state, runner_state, harness_state} do
        {:observation_failed, _, _} -> :observation_failed
        {:permission_unknown, _, _} -> :permission_unknown
        {_, :permission_unknown, _} -> :permission_unknown
        {_, _, :permission_unknown} -> :permission_unknown
        {:absent, :absent, _} -> :absent
        {:absent, :missing, _} -> :absent
        {:verified, :absent, :verified} -> :orphaned_runner
        {:verified, :verified, :verified} -> :verified
        _ -> :identity_mismatch
      end
    else
      {:error, :unsafe_pgid} -> :identity_mismatch
      {:error, :identity} -> :identity_mismatch
      {:error, :observation_failed} -> :observation_failed
    end
  end

  def liveness(_manifest), do: :identity_mismatch

  def path_for(home, attempt_id) do
    Path.join([Home.runtime_attempts_dir(home), to_string(attempt_id), "manifest.json"])
  end

  defp canonical_path(path, home) do
    runtime = Path.expand(Home.runtime_attempts_dir(home))
    expanded = Path.expand(path)

    if String.starts_with?(expanded, runtime <> "/") and
         Path.basename(expanded) == "manifest.json" do
      :ok
    else
      {:error, :identity}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :corrupt}
    end
  end

  defp read_manifest(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= Limits.frame_bytes(),
         {:ok, body} <- File.read(path),
         {:ok, trimmed} <- Limits.validate_json_frame(body),
         {:ok, manifest} <- decode(trimmed) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, :enoent}
      false -> {:error, :corrupt}
      {:error, _reason} -> {:error, :corrupt}
    end
  end

  defp schema(%{"schema_version" => 1, "attempt_id" => id, "state" => state})
       when is_binary(id) and is_binary(state),
       do: :ok

  defp schema(_), do: {:error, :corrupt}

  defp path_identity(path, %{"attempt_id" => id}) do
    if Path.basename(Path.dirname(Path.expand(path))) == id do
      :ok
    else
      {:error, :identity}
    end
  end

  defp safe_pgid(%{"pgid" => pgid}) when is_integer(pgid) and pgid > 1, do: :ok
  defp safe_pgid(%{"pgid" => pgid}) when is_integer(pgid), do: {:error, :unsafe_pgid}
  defp safe_pgid(%{"pgid" => _}), do: {:error, :unsafe_pgid}
  defp safe_pgid(_), do: :ok

  defp socket_path(%{"control_socket_path" => socket}, home) when is_binary(socket) do
    runtime = Path.expand(Home.runtime_attempts_dir(home))
    expanded = Path.expand(socket)

    if String.starts_with?(expanded, runtime <> "/") do
      :ok
    else
      {:error, :identity}
    end
  end

  defp socket_path(_, _), do: :ok

  defp matching_attempt(%{"attempt_id" => id} = manifest) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Attempt, uuid) do
          %Attempt{} = attempt -> match_row(manifest, attempt)
          nil -> {:error, :identity}
        end

      :error ->
        {:error, :identity}
    end
  end

  defp match_row(manifest, attempt) do
    workspace =
      if attempt.workspace_id,
        do: Repo.get(Consigliere.Workspaces.Workspace, attempt.workspace_id)

    cond do
      mission_mismatch?(manifest, attempt) -> {:error, :identity}
      fence_mismatch?(manifest, attempt) -> {:error, :stale}
      workspace_mismatch?(manifest, workspace) -> {:error, :identity}
      generation_mismatch?(manifest, attempt, workspace) -> {:error, :stale}
      true -> {:ok, attempt}
    end
  end

  defp workspace_mismatch?(%{"workspace_path" => path}, %{path: expected})
       when is_binary(path) and is_binary(expected),
       do: Path.expand(path) != Path.expand(expected)

  defp workspace_mismatch?(_, _), do: false

  defp generation_mismatch?(manifest, attempt, workspace) do
    Enum.any?(
      [
        {manifest["workspace_generation"], workspace && workspace.lease_id},
        {manifest["fencing_generation"], attempt.fencing_token}
      ],
      fn
        {nil, _expected} -> false
        {given, expected} when is_binary(given) and is_binary(expected) -> given != expected
        {_given, _expected} -> true
      end
    )
  end

  defp mission_mismatch?(%{"mission_id" => id}, attempt) when is_binary(id),
    do: id != attempt.mission_id

  defp mission_mismatch?(_, _), do: false

  defp fence_mismatch?(%{"fencing_token" => token}, attempt) when is_binary(token),
    do: token != attempt.fencing_token

  defp fence_mismatch?(_, _), do: false

  defp classify(%{"state" => state} = manifest, attempt) when state in @live,
    do: {:valid_live, manifest, attempt}

  defp classify(%{"state" => state} = manifest, attempt) when state in @dead,
    do: {:valid_terminal, manifest, attempt}

  defp classify(_, _), do: {:error, :corrupt}

  defp group_liveness(%{"pgid" => pgid}) when is_integer(pgid) and pgid > 1,
    do: {:ok, ProcessGroup.liveness(pgid)}

  defp group_liveness(_), do: {:error, :unsafe_pgid}

  defp runner_identity(%{"runner_pid" => pid} = manifest) when is_integer(pid) and pid > 1 do
    identity_state(
      pid,
      manifest["pgid"],
      manifest["runner_executable_path"],
      manifest["runner_executable_sha256"]
    )
  end

  defp runner_identity(_), do: {:ok, :missing}

  defp harness_identity(%{"harness_pid" => pid} = manifest) when is_integer(pid) and pid > 1 do
    identity_state(
      pid,
      manifest["pgid"],
      manifest["harness_executable_path"],
      manifest["harness_executable_sha256"]
    )
  end

  defp harness_identity(_), do: {:ok, :missing}

  defp identity_state(pid, pgid, executable_path, executable_sha256) do
    case ProcessIdentity.verify(pid, executable_path, executable_sha256) do
      :verified ->
        if ProcessGroup.member?(pid, pgid), do: {:ok, :verified}, else: {:error, :identity}

      :absent ->
        {:ok, :absent}

      :identity_mismatch ->
        {:error, :identity}

      :permission_unknown ->
        {:ok, :permission_unknown}

      :observation_failed ->
        {:error, :observation_failed}
    end
  end
end
