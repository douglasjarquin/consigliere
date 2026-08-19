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
    if pgid_alive?.() do
      {:adopt_and_kill, manifest}
    else
      {:lost, manifest}
    end
  end

  def classify_manifest(manifest, _pgid_alive?) do
    {:quarantine_incident, manifest}
  end

  defp process_group_alive?(pgid) when is_integer(pgid) do
    match?({_, 0}, System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true))
  end

  defp process_group_alive?(_), do: false
end
