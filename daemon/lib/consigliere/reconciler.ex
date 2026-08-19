defmodule Consigliere.Reconciler do
  @moduledoc """
  Spike C: classifies a runner manifest per the "Restart and reconciliation
  contract" in docs/protocols/runner.md. This is the spike-scoped
  classification function only -- it does not cross-reference an Attempt row
  or perform any SQLite write, since this spike models no real Mission or
  Attempt schema (see docs/spikes/spike-c-results.md for the scope decision).
  """

  @non_terminal_states ["starting", "running", "terminating"]

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
    # System.cmd raises (rather than returning an error tuple) if the "kill"
    # executable itself cannot be found. The reconciler must make forward
    # progress on every manifest per docs/protocols/runner.md:141, so this
    # unverifiable case defaults to "alive" like every other one, not to a
    # crash that would halt reconciliation of every other manifest too.
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
end
