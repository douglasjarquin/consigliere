defmodule Consigliere.Made.Process do
  @moduledoc """
  Short-lived `made validate --managed` adapter. The validator process
  is always gone before this function returns (ADR-007).
  """

  @outcomes %{
    0 => :passed,
    2 => :needs_decision,
    3 => :failed_retryable,
    4 => :failed_terminal,
    5 => :infrastructure_error,
    6 => :canceled
  }

  def validate(spec) do
    binary = binary()
    decisions_path = write_decisions!(spec)
    {output, status} = run(binary, spec, decisions_path)
    _ = File.rm(decisions_path)
    live_pid = nil
    outcome = Map.get(@outcomes, status, :infrastructure_error)

    %{
      outcome: outcome,
      exit_code: status,
      output: output,
      events: parse_events(output),
      live_pid: live_pid,
      findings: findings(output)
    }
  end

  def binary do
    System.get_env("CS_MADE_BIN") || System.find_executable("made") || fixture_binary()
  end

  def fixture_binary do
    Path.join(:code.priv_dir(:consigliere_daemon), "fake_made.sh")
  end

  defp run(binary, spec, decisions_path) do
    args = [
      "validate",
      "--managed",
      "--run-id",
      to_string(spec.run_id),
      "--workspace",
      to_string(Map.get(spec, :workspace) || Map.get(spec, :workspace_path) || "."),
      "--input-sha",
      to_string(spec.input_sha),
      "--base-sha",
      to_string(spec.base_sha),
      "--policy-hash",
      to_string(spec.policy_hash),
      "--decisions",
      decisions_path,
      "--json-events"
    ]

    env = [
      {"CS_FAKE_MADE_OUTCOME", outcome_name(spec)},
      {"CS_FAKE_MADE_FINGERPRINT", to_string(Map.get(spec, :fingerprint, "fp-default"))}
    ]

    System.cmd(binary, args, stderr_to_stdout: true, env: env)
  end

  defp outcome_name(spec) do
    case Map.get(spec, :forced_outcome) do
      nil -> ""
      atom -> Atom.to_string(atom)
    end
  end

  defp write_decisions!(spec) do
    path =
      Path.join(System.tmp_dir!(), "cs-made-decisions-#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(Map.get(spec, :decisions, [])))
    path
  end

  defp parse_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, map} -> [map]
        _ -> []
      end
    end)
  end

  defp findings(output) do
    parse_events(output)
    |> Enum.flat_map(fn
      %{"event" => "stage.finding", "finding" => finding} -> [finding]
      %{"event" => "run.needs_decision", "findings" => list} when is_list(list) -> list
      _ -> []
    end)
  end
end
