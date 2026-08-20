defmodule Consigliere.Reconciler do
  @moduledoc """
  Batch reconciliation pass over runner manifests and occupying Attempts.

  Not a supervisor of anything (docs/architecture/runtime.md). Classification
  of a manifest is the Spike C function; this process cross-references the
  Attempt row and writes through DatabaseWriter. One corrupt manifest never
  halts the rest (docs/protocols/runner.md).
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DatabaseWriter
  alias Consigliere.GlobalScheduler
  alias Consigliere.Home
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions.Mission
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Txn

  @non_terminal_states ["starting", "running", "terminating"]
  @occupying ~w(starting running checkpoint_requested)
  @terminal ~w(completed failed lost canceled superseded)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  def run(opts \\ []) do
    home = Keyword.get(opts, :home, Home.dir())
    do_run(home)
  end

  def classify(manifest_path) do
    with {:ok, data} <- File.read(manifest_path),
         {:ok, manifest} <- JSON.decode(data) do
      classify_manifest(manifest, fn -> process_group_alive?(manifest["pgid"]) end)
    else
      _ -> {:quarantine_incident, :corrupt}
    end
  end

  def classify_manifest(%{"state" => "dead_verified"} = manifest, _pgid_alive?) do
    {:lost, manifest}
  end

  def classify_manifest(%{"state" => "dead_unverified"} = manifest, _pgid_alive?) do
    {:quarantine_incident, manifest}
  end

  def classify_manifest(%{"state" => state} = manifest, pgid_alive?)
      when state in @non_terminal_states do
    case manifest["pgid"] do
      pgid when is_integer(pgid) and pgid > 1 ->
        if pgid_alive?.() do
          {:adopt_and_kill, manifest}
        else
          {:lost, manifest}
        end

      _ ->
        {:quarantine_incident, manifest}
    end
  end

  def classify_manifest(manifest, _pgid_alive?) do
    {:quarantine_incident, manifest}
  end

  defp process_group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    kill_result_alive?(System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true))
  rescue
    _ -> true
  end

  defp process_group_alive?(_), do: true

  @doc """
  Interprets the output of `kill -0 -<pgid>`. Only an explicit "No such
  process" (ESRCH-equivalent) is conclusive evidence of death; any other
  failure (in particular "Operation not permitted"/EPERM after a permissions
  change, the exact case docs/protocols/runner.md names) means the liveness
  check itself is unreliable and must never be read as "gone" -- reusing a
  workspace under a live process is the unsafe direction, so an unverifiable
  result defaults to "alive".
  """
  def kill_result_alive?({_output, 0}), do: true

  def kill_result_alive?({output, _status}) do
    not String.contains?(output, "No such process")
  end

  @impl true
  def init(opts) do
    env = Application.get_env(:consigliere_daemon, __MODULE__, [])
    interval = Keyword.get(opts, :poll_interval_ms, Keyword.get(env, :poll_interval_ms, 5_000))
    run_on_boot = Keyword.get(opts, :run_on_boot, Keyword.get(env, :run_on_boot, true))
    state = %{poll_interval_ms: interval}

    if run_on_boot do
      {:ok, state, {:continue, :run}}
    else
      schedule_tick(interval)
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:run, state) do
    _ = do_run(Home.dir())
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:run, home}, _from, state) do
    {:reply, do_run(home), state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = do_run(Home.dir())
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  defp do_run(home) do
    paths = Path.wildcard(Path.join([home, "runners", "*", "manifest.json"]))
    seen = MapSet.new()

    {manifest_results, seen} =
      Enum.map_reduce(paths, seen, fn path, seen ->
        result = safe(path, fn -> reconcile_manifest(path) end)
        {result, remember(seen, result)}
      end)

    attempt_results =
      occupying_attempts()
      |> Enum.reject(fn attempt -> MapSet.member?(seen, attempt.id) or runner_live?(attempt.id) end)
      |> Enum.map(fn attempt -> safe(attempt.id, fn -> reconcile_attempt_without_manifest(attempt) end) end)

    manifest_results ++ attempt_results
  end

  defp reconcile_manifest(path) do
    case classify(path) do
      {:quarantine_incident, :corrupt} ->
        record_incident(%{severity: "warning", reason: "corrupt runner manifest: #{path}"})
        {:incident, :corrupt}

      {kind, manifest} when is_map(manifest) ->
        apply_manifest(kind, manifest)

      other ->
        {:skipped, other}
    end
  end

  defp apply_manifest(kind, manifest) do
    attempt = fetch_attempt(manifest["attempt_id"])

    cond do
      is_nil(attempt) ->
        _ = adopt_kill(kind, manifest)

        record_incident(%{
          severity: "warning",
          reason: "manifest #{kind} with no Attempt row (#{manifest["attempt_id"]})"
        })

        {:orphan, kind}

      attempt.status in @terminal ->
        {:skipped, attempt.id}

      runner_live?(attempt.id) ->
        {:skipped, attempt.id}

      kind == :lost ->
        finalize_dead(attempt, :dead_verified)

      kind == :quarantine_incident ->
        finalize_dead(attempt, :unconfirmed)

      kind == :adopt_and_kill ->
        record_incident(%{
          mission_id: attempt.mission_id,
          subject_type: "attempt",
          subject_id: attempt.id,
          severity: "warning",
          reason: "orphaned live process group; adopt-and-kill"
        })

        finalize_dead(attempt, adopt_kill(kind, manifest))
    end
  end

  defp reconcile_attempt_without_manifest(attempt) do
    cond do
      runner_live?(attempt.id) ->
        {:skipped, attempt.id}

      valid_pgid?(attempt.pgid) and process_group_alive?(attempt.pgid) ->
        record_incident(%{
          mission_id: attempt.mission_id,
          subject_type: "attempt",
          subject_id: attempt.id,
          severity: "warning",
          reason: "occupying Attempt has no manifest and a live process group"
        })

        finalize_dead(attempt, adopt_kill(:adopt_and_kill, %{"pgid" => attempt.pgid}))

      valid_pgid?(attempt.pgid) ->
        finalize_dead(attempt, :dead_verified)

      true ->
        finalize_dead(attempt, :unconfirmed)
    end
  end

  defp finalize_dead(attempt, inventory) do
    result =
      if checkpoint_imported?(attempt) do
        Attempts.record_checkpointed(attempt.id, Actor.system(), %{
          imported_sha: attempt.reported_checkpoint_sha,
          process_group: :dead_verified
        })

        {:checkpointed, attempt.id}
      else
        Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: inventory})
        if inventory == :unconfirmed, do: {:quarantined, attempt.id}, else: {:lost, attempt.id}
      end

    _ = GlobalScheduler.release_slot(attempt.mission_id)
    result
  end

  defp checkpoint_imported?(attempt) do
    attempt.status == "checkpoint_requested" and
      is_binary(attempt.reported_checkpoint_sha) and
      case Repo.get(Mission, attempt.mission_id) do
        %Mission{current_checkpoint_sha: sha} -> sha == attempt.reported_checkpoint_sha
        _ -> false
      end
  end

  defp occupying_attempts do
    Repo.all(from a in Attempt, where: a.status in ^@occupying)
  end

  defp fetch_attempt(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Attempt, uuid)
      :error -> nil
    end
  end

  defp fetch_attempt(_), do: nil

  defp runner_live?(attempt_id) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  defp valid_pgid?(pgid) when is_integer(pgid) and pgid > 1, do: true
  defp valid_pgid?(_), do: false

  defp adopt_kill(:adopt_and_kill, %{"pgid" => pgid}) do
    if ProcessGroup.terminate(pgid) == :dead_verified, do: :dead_verified, else: :unconfirmed
  end

  defp adopt_kill(_, _), do: :unconfirmed

  defp remember(seen, {:lost, id}) when is_binary(id), do: MapSet.put(seen, id)
  defp remember(seen, {:quarantined, id}) when is_binary(id), do: MapSet.put(seen, id)
  defp remember(seen, {:checkpointed, id}) when is_binary(id), do: MapSet.put(seen, id)
  defp remember(seen, {:adopt_and_kill, id}) when is_binary(id), do: MapSet.put(seen, id)
  defp remember(seen, {:skipped, id}) when is_binary(id), do: MapSet.put(seen, id)
  defp remember(seen, _), do: seen

  defp record_incident(attrs) do
    DatabaseWriter.transaction(fn ->
      Txn.insert!(Incident.changeset(%Incident{}, attrs))
    end)
  end

  defp safe(item, fun) do
    fun.()
  rescue
    exception -> {:error, {item, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {item, "#{kind}: #{inspect(reason)}"}}
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end
end
