defmodule Consigliere.Runtime.Inventory do
  @moduledoc """
  Canonical runtime-manifest verifier. A PID/PGID is signalable only
  from a live inventory record whose path, Attempt, Mission, and fence
  all match.
  """

  alias Consigliere.Attempts.Attempt
  alias Consigliere.Home
  alias Consigliere.Repo

  @live ~w(starting running terminating)
  @dead ~w(dead_verified dead_unverified)

  def signalable?({:valid_live, manifest, _attempt}) do
    pgid = manifest["pgid"]
    is_integer(pgid) and pgid > 1
  end

  def signalable?(_), do: false

  def verify(path, home) do
    with :ok <- canonical_path(path, home),
         {:ok, body} <- File.read(path),
         {:ok, manifest} <- decode(body),
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
      :error -> :corrupt
      _ -> :corrupt
    end
  end

  def path_for(home, attempt_id) do
    Path.join([Home.runtime_attempts_dir(home), to_string(attempt_id), "manifest.json"])
  end

  defp canonical_path(path, home) do
    runtime = Path.expand(Home.runtime_attempts_dir(home))
    expanded = Path.expand(path)

    if String.starts_with?(expanded, runtime <> "/") and Path.basename(expanded) == "manifest.json" do
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
    cond do
      mission_mismatch?(manifest, attempt) -> {:error, :identity}
      fence_mismatch?(manifest, attempt) -> {:error, :stale}
      true -> {:ok, attempt}
    end
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
end
