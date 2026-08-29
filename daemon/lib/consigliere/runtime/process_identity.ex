defmodule Consigliere.Runtime.ProcessIdentity do
  @moduledoc false

  def verify(pid, expected_executable \\ nil, expected_hash \\ nil)

  def verify(pid, expected_executable, expected_hash)
      when is_integer(pid) and pid > 1 do
    case System.cmd("ps", ["-o", "pid=,comm=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case parse(output, pid) do
          {:ok, executable} ->
            cond do
              not executable_matches?(executable, expected_executable) ->
                :identity_mismatch

              is_binary(expected_hash) and expected_hash != "" and is_binary(expected_executable) ->
                verify_hash(expected_executable, expected_hash)

              true ->
                :verified
            end

          :absent ->
            :absent

          :invalid ->
            :observation_failed
        end

      {output, _status} ->
        cond do
          String.trim(output) == "" ->
            :absent

          String.contains?(String.downcase(output), "operation not permitted") ->
            :permission_unknown

          true ->
            :observation_failed
        end
    end
  rescue
    _ -> :observation_failed
  end

  def verify(_pid, _expected_executable, _expected_hash), do: :identity_mismatch

  defp parse(output, pid) do
    case output |> String.trim() |> String.split("\n", trim: true) do
      [] ->
        :absent

      [line | _] ->
        case String.split(String.trim(line), ~r/\s+/, parts: 2) do
          [pid_text, executable] ->
            case Integer.parse(pid_text) do
              {^pid, _} -> {:ok, String.trim(executable)}
              _ -> :invalid
            end

          _ ->
            :invalid
        end
    end
  end

  defp executable_matches?(_actual, nil), do: true

  defp executable_matches?(actual, expected) when is_binary(expected) do
    actual == expected or Path.basename(actual) == Path.basename(expected)
  end

  defp executable_matches?(_actual, _expected), do: false

  defp verify_hash(path, expected) when is_binary(path) do
    case System.cmd("shasum", ["-a", "256", path], stderr_to_stdout: true) do
      {output, 0} ->
        [actual | _] = String.split(String.trim(output))
        if actual == expected, do: :verified, else: :identity_mismatch

      {output, _status} ->
        if String.contains?(String.downcase(output), "operation not permitted"),
          do: :permission_unknown,
          else: :observation_failed
    end
  rescue
    _ -> :observation_failed
  end
end
