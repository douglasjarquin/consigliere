defmodule Consigliere.Runtime.ProcessIdentity do
  @moduledoc false

  def verify(pid, expected_executable \\ nil, expected_hash \\ nil)

  def verify(pid, expected_executable, expected_hash)
      when is_integer(pid) and pid > 1 do
    case actual_executable(pid) do
      {:ok, executable} ->
        cond do
          not executable_matches?(executable, expected_executable) ->
            :identity_mismatch

          is_binary(expected_hash) and expected_hash != "" ->
            verify_hash(executable, expected_hash)

          true ->
            :verified
        end

      :absent ->
        :absent

      {:error, result} ->
        result
    end
  rescue
    _ -> :observation_failed
  end

  def verify(_pid, _expected_executable, _expected_hash), do: :identity_mismatch

  defp actual_executable(pid) do
    case :os.type() do
      {:unix, :linux} -> linux_executable(pid)
      {:unix, :darwin} -> darwin_executable(pid)
      _ -> ps_executable(pid)
    end
  end

  defp linux_executable(pid) do
    case File.read_link("/proc/#{pid}/exe") do
      {:ok, executable} -> {:ok, executable}
      {:error, reason} -> classify_file_error(reason)
    end
  end

  defp darwin_executable(pid) do
    case System.find_executable("lsof") do
      nil ->
        {:error, :observation_failed}

      lsof ->
        case System.cmd(lsof, ["-a", "-p", Integer.to_string(pid), "-d", "txt", "-Fn"],
               stderr_to_stdout: true
             ) do
          {output, 0} -> parse_lsof(output)
          {output, _status} -> classify_command_output(output)
        end
    end
  end

  defp ps_executable(pid) do
    case System.cmd("ps", ["-o", "pid=,comm=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case parse_ps(output, pid) do
          {:ok, executable} -> {:ok, executable}
          :absent -> :absent
          :invalid -> {:error, :observation_failed}
        end

      {output, _status} ->
        classify_command_output(output)
    end
  end

  defp parse_lsof(output) do
    case Regex.run(~r/(?:\A|\n)ftxt\nn([^\n]+)/, output, capture: :all_but_first) do
      [executable] when executable != "" -> {:ok, String.trim(executable)}
      _ -> if String.trim(output) == "", do: :absent, else: {:error, :observation_failed}
    end
  end

  defp parse_ps(output, pid) do
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

  defp classify_file_error(reason) when reason in [:enoent, :enotdir], do: :absent

  defp classify_file_error(reason) when reason in [:eacces, :eperm],
    do: {:error, :permission_unknown}

  defp classify_file_error(_reason), do: {:error, :observation_failed}

  defp classify_command_output(output) do
    cond do
      String.trim(output) == "" ->
        :absent

      String.contains?(String.downcase(output), "operation not permitted") ->
        {:error, :permission_unknown}

      String.contains?(String.downcase(output), "no such process") ->
        :absent

      true ->
        {:error, :observation_failed}
    end
  end

  defp executable_matches?(_actual, nil), do: true

  defp executable_matches?(actual, expected) when is_binary(expected) do
    canonical_path(actual) == canonical_path(expected)
  end

  defp executable_matches?(_actual, _expected), do: false

  defp canonical_path(path) do
    expanded = Path.expand(path)

    case System.find_executable("realpath") do
      nil ->
        expanded

      realpath ->
        case System.cmd(realpath, [expanded], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> expanded
        end
    end
  rescue
    _ -> Path.expand(path)
  end

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
