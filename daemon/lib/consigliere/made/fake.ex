defmodule Consigliere.Made.Fake do
  @moduledoc """
  In-process stand-in for `made validate --managed`. It always exits; a
  needs_decision outcome never leaves a live validator process (ADR-007).
  """

  def validate(spec) do
    {outcome, code} = outcome_and_code(spec)
    {output, status} = System.cmd("sh", ["-c", "exit #{code}"], stderr_to_stdout: true)

    %{
      outcome: if(status == 0, do: :passed, else: outcome),
      exit_code: status,
      output: output,
      live_pid: nil
    }
  end

  defp outcome_and_code(spec) do
    case Map.get(spec, :forced_outcome) do
      :passed -> {:passed, 0}
      :failed_terminal -> {:failed_terminal, 4}
      :needs_decision -> {:needs_decision, 2}
      nil -> if waived?(spec), do: {:passed, 0}, else: {:needs_decision, 2}
      other -> {other, 2}
    end
  end

  defp waived?(spec) do
    fingerprint = Map.get(spec, :fingerprint, "fp-default")
    input_sha = spec.input_sha

    Enum.any?(Map.get(spec, :decisions, []), fn d ->
      d["fingerprint"] == fingerprint and sha_applies?(d, input_sha)
    end)
  end

  defp sha_applies?(%{"scope" => "sha_bound", "input_sha" => sha}, input_sha),
    do: sha == input_sha

  defp sha_applies?(%{"scope" => "sha_bound"}, _), do: false
  defp sha_applies?(_, _), do: true
end
