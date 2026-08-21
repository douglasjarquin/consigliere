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

  alias Consigliere.AttemptStates
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Home
  alias Consigliere.ProcessGroup
  alias Consigliere.Reconciler.Pass
  alias Consigliere.Repo
  alias Consigliere.Runtime.Inventory

  @non_terminal_states ["starting", "running", "terminating"]

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
    ProcessGroup.alive?(pgid)
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
    paths = Path.wildcard(Path.join([Home.runtime_attempts_dir(home), "*", "manifest.json"]))
    seen = MapSet.new()

    {manifest_results, seen} =
      Enum.map_reduce(paths, seen, fn path, seen ->
        result = safe(path, fn -> reconcile_path(path, home) end)
        {result, remember(seen, result)}
      end)

    attempt_results =
      occupying_attempts()
      |> Enum.reject(fn attempt ->
        MapSet.member?(seen, attempt.id) or runner_live?(attempt.id)
      end)
      |> Enum.map(fn attempt ->
        safe(attempt.id, fn -> reconcile_attempt_without_manifest(attempt, home) end)
      end)

    manifest_results ++ attempt_results
  end

  defp reconcile_path(path, home) do
    case Inventory.verify(path, home) do
      {:valid_live, manifest, attempt} ->
        Pass.apply_live(manifest, attempt, runner_live?(attempt.id))

      {:valid_terminal, manifest, attempt} ->
        Pass.apply_terminal_manifest(manifest, attempt, runner_live?(attempt.id))

      :identity_mismatch ->
        Pass.mismatch(path, :identity)

      :stale_generation ->
        Pass.mismatch(path, :stale)

      :unsafe_pgid ->
        Pass.mismatch(path, :unsafe_pgid)

      :corrupt ->
        Pass.corrupt(path)

      :missing ->
        {:skipped, :missing}
    end
  end

  defp reconcile_attempt_without_manifest(attempt, _home) do
    Pass.without_manifest(attempt, runner_live?(attempt.id))
  end

  defp occupying_attempts do
    statuses = AttemptStates.process_may_exist()
    Repo.all(from(a in Attempt, where: a.status in ^statuses))
  end

  defp runner_live?(attempt_id) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  defp remember(seen, {tag, id})
       when is_binary(id) and
              tag in [
                :lost,
                :quarantined,
                :checkpointed,
                :adopt_and_kill,
                :skipped,
                :reaped,
                :completed,
                :failed
              ],
       do: MapSet.put(seen, id)

  defp remember(seen, _), do: seen

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
