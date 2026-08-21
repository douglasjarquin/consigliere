defmodule Consigliere.Made.Process do
  @moduledoc """
  Short-lived `made validate --managed` adapter. Production never falls
  back to a fixture. The validator is gone before this returns.
  """

  alias Consigliere.Home
  alias Consigliere.Made.Events
  alias Consigliere.Made.Exec

  @outcomes %{
    0 => :passed,
    2 => :needs_decision,
    3 => :failed_retryable,
    4 => :failed_terminal,
    5 => :infrastructure_error,
    6 => :canceled
  }

  @named %{
    "passed" => :passed,
    "needs_decision" => :needs_decision,
    "failed_retryable" => :failed_retryable,
    "failed_terminal" => :failed_terminal,
    "infrastructure_error" => :infrastructure_error,
    "canceled" => :canceled
  }

  def validate(spec) do
    case resolve_binary() do
      {:ok, binary} -> run_validate(binary, spec)
      {:error, reason} -> fail_closed(reason)
    end
  end

  def resolve_binary do
    case System.get_env("CS_MADE_BIN") do
      path when is_binary(path) and path != "" -> usable(path)
      _ -> find_made()
    end
  end

  def binary do
    case resolve_binary() do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, "made binary #{reason}"
    end
  end

  def fixture_binary do
    Path.join(:code.priv_dir(:consigliere_daemon), "fake_made.sh")
  end

  defp find_made do
    case System.find_executable("made") do
      nil -> {:error, :made_missing}
      path -> if fixture?(path), do: {:error, :made_fixture_forbidden}, else: usable(path)
    end
  end

  defp usable(path) do
    if File.regular?(path) and executable?(path), do: {:ok, path}, else: {:error, :made_unusable}
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp fixture?(path), do: Path.expand(path) == Path.expand(fixture_binary())

  defp run_validate(binary, spec) do
    identity = identity(spec)
    {dir, decisions_path} = write_decisions!(spec, identity)
    tmpdir = Path.join(dir, "tmp")
    File.mkdir_p!(tmpdir)
    File.chmod!(tmpdir, 0o700)

    result =
      case Exec.run(binary, args(spec, identity, decisions_path), env(binary, spec, tmpdir),
             timeout_ms: Map.get(spec, :timeout_ms, 30_000)
           ) do
        {:ok, output, status, _pid} ->
          finish(output, status, identity)

        {:error, reason, output, _pid} ->
          fail_closed(reason, output)
      end

    _ = File.rm(decisions_path)
    result
  end

  defp finish(output, status, identity) do
    expected = Map.get(@outcomes, status, :infrastructure_error)

    case Events.parse(output, identity) do
      {:ok, parsed} ->
        terminal = Map.get(@named, parsed.terminal["outcome"])

        if terminal == expected do
          %{
            outcome: terminal,
            exit_code: status,
            output: output,
            events: parsed.events,
            findings: parsed.findings,
            live_pid: nil
          }
        else
          fail_closed(:exit_mismatch, output)
        end

      {:error, reason} ->
        fail_closed(reason, output)
    end
  end

  defp fail_closed(reason, output \\ "") do
    %{
      outcome: :infrastructure_error,
      exit_code: nil,
      output: output,
      events: [],
      findings: [],
      live_pid: nil,
      reason: reason
    }
  end

  defp identity(spec) do
    %{
      run_id: to_string(spec.run_id),
      invocation_id: to_string(Map.get(spec, :invocation_id) || spec.run_id),
      mission_id: to_string(Map.get(spec, :mission_id) || ""),
      gate_id: to_string(Map.get(spec, :gate_id) || spec.run_id),
      base_sha: to_string(spec.base_sha),
      input_sha: to_string(spec.input_sha),
      policy_hash: to_string(spec.policy_hash)
    }
  end

  defp args(spec, identity, decisions_path) do
    [
      "validate",
      "--managed",
      "--json-events",
      "--run-id",
      identity.run_id,
      "--invocation-id",
      identity.invocation_id,
      "--mission-id",
      identity.mission_id,
      "--gate-id",
      identity.gate_id,
      "--workspace",
      to_string(Map.get(spec, :workspace) || Map.get(spec, :workspace_path) || "."),
      "--input-sha",
      identity.input_sha,
      "--base-sha",
      identity.base_sha,
      "--policy-hash",
      identity.policy_hash,
      "--decisions",
      decisions_path
    ]
  end

  defp env(binary, spec, tmpdir) do
    path = Enum.join([Path.dirname(binary), "/usr/bin", "/bin", "/usr/sbin"], ":")

    [
      {"PATH", path},
      {"LANG", "C"},
      {"LC_ALL", "C"},
      {"TMPDIR", tmpdir},
      {"CS_FAKE_MADE_OUTCOME", outcome_name(spec)},
      {"CS_FAKE_MADE_FINGERPRINT", to_string(Map.get(spec, :fingerprint, "fp-default"))}
    ]
  end

  defp outcome_name(spec) do
    case Map.get(spec, :forced_outcome) do
      nil -> ""
      atom -> Atom.to_string(atom)
    end
  end

  defp write_decisions!(spec, identity) do
    dir =
      Path.join([
        Home.evidence_dir(),
        "validation",
        identity.run_id,
        identity.invocation_id
      ])

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "decisions.json")

    payload = %{
      "run_id" => identity.run_id,
      "invocation_id" => identity.invocation_id,
      "mission_id" => identity.mission_id,
      "gate_id" => identity.gate_id,
      "input_sha" => identity.input_sha,
      "base_sha" => identity.base_sha,
      "policy_hash" => identity.policy_hash,
      "decisions" => Map.get(spec, :decisions, [])
    }

    File.write!(path, JSON.encode!(payload))
    File.chmod!(path, 0o600)
    {dir, path}
  end
end
