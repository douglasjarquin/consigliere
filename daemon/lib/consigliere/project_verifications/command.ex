defmodule Consigliere.ProjectVerifications.Command do
  @moduledoc false

  alias Consigliere.Harness.Redaction
  @max_output 65_536
  @safe_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

  def run(argv, workspace, opts \\ [])

  def run(argv, workspace, opts) when is_list(argv) and is_binary(workspace) do
    cond do
      Keyword.get(opts, :cancel, false) ->
        %{outcome: "canceled", error_code: "canceled"}

      not File.dir?(workspace) ->
        %{outcome: "infrastructure_error", error_code: "workspace_missing"}

      true ->
        do_run(argv, workspace, opts)
    end
  end

  def run(_, _, _), do: %{outcome: "infrastructure_error", error_code: "command_invalid"}

  defp do_run([command | args], workspace, opts) do
    case resolve(command) do
      nil -> %{outcome: "infrastructure_error", error_code: "command_missing"}
      executable -> open_port(executable, args, workspace, opts)
    end
  end

  defp open_port(executable, args, workspace, opts) do
    case resolve("env") do
      nil ->
        %{outcome: "infrastructure_error", error_code: "command_missing"}

      env_executable ->
        port =
          Port.open(
            {:spawn_executable, env_executable},
            [
              :binary,
              :exit_status,
              args: ["-i" | environment_args() ++ [executable | args]],
              cd: workspace
            ]
          )

        collect(
          port,
          "",
          System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 900_000),
          opts
        )
    end
  rescue
    _ -> %{outcome: "infrastructure_error", error_code: "command_spawn_failed"}
  end

  defp collect(port, output, deadline, opts) do
    remaining =
      min(
        deadline - System.monotonic_time(:millisecond),
        Keyword.get(opts, :total_timeout_ms, 1_800_000)
      )

    if remaining <= 0 do
      close_port(port)
      result("infrastructure_error", output, nil, true, "timeout")
    else
      receive do
        {^port, {:data, data}} ->
          if byte_size(output) + byte_size(data) > @max_output do
            close_port(port)
            remaining = @max_output - byte_size(output)

            bounded_output =
              if remaining > 0 do
                output <> binary_part(data, 0, remaining)
              else
                output
              end

            result(
              "infrastructure_error",
              bounded_output,
              nil,
              false,
              "output_too_large"
            )
          else
            collect(port, output <> data, deadline, opts)
          end

        {^port, {:exit_status, status}} ->
          outcome = if status == 0, do: "passed", else: "failed"
          result(outcome, output, status, false, nil)
      after
        remaining ->
          close_port(port)
          result("infrastructure_error", output, nil, true, "timeout")
      end
    end
  end

  defp result(outcome, output, status, timed_out, error_code) do
    safe = Redaction.text(output)

    %{
      outcome: outcome,
      exit_status: status,
      timed_out: timed_out,
      output_bytes: byte_size(safe),
      output_digest: :crypto.hash(:sha256, safe) |> Base.encode16(case: :lower),
      error_code: error_code
    }
  end

  defp resolve(command) when is_binary(command) do
    candidates =
      if String.contains?(command, "/"),
        do: [Path.expand(command)],
        else: Enum.map(String.split(@safe_path, ":"), &Path.join(&1, command))

    Enum.find(candidates, fn path -> File.regular?(path) and executable?(path) end)
  end

  defp resolve(_), do: nil

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp scrubbed_env do
    [
      {~c"PATH", String.to_charlist(@safe_path)},
      {~c"LANG", ~c"C"},
      {~c"LC_ALL", ~c"C"},
      {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
      {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
      {~c"GIT_CONFIG_SYSTEM", ~c"/dev/null"},
      {~c"GIT_TERMINAL_PROMPT", ~c"0"},
      {~c"GIT_ASKPASS", ~c""}
    ]
  end

  defp environment_args do
    Enum.map(scrubbed_env(), fn {key, value} ->
      to_string(key) <> "=" <> to_string(value)
    end)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end
end
