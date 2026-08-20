defmodule Consigliere.Made.Fake do
  @moduledoc """
  In-process stand-in for `made validate --managed`. It always exits; a
  needs_decision outcome never leaves a live validator process (ADR-007).
  """

  def validate(spec) do
    code = if waived?(spec), do: 0, else: 2
    {output, status} = System.cmd("sh", ["-c", "exit #{code}"], stderr_to_stdout: true)

    %{
      outcome: if(status == 0, do: :passed, else: :needs_decision),
      exit_code: status,
      output: output,
      live_pid: nil
    }
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
