defmodule Consigliere.Runtime.ProcessIdentity do
  @moduledoc false

  @tool_paths %{
    ps: ["/bin/ps", "/usr/bin/ps"],
    lsof: ["/usr/sbin/lsof", "/usr/bin/lsof"],
    realpath: ["/bin/realpath", "/usr/bin/realpath"],
    shasum: ["/usr/bin/shasum", "/bin/shasum"]
  }

  alias Consigliere.Runtime.Command

  def verify(pid, expected_executable \\ nil, expected_hash \\ nil, expected_start \\ nil)

  def verify(pid, expected_executable, expected_hash, expected_start)
      when is_integer(pid) and pid > 1 do
    case actual_executable(pid) do
      {:ok, executable} ->
        cond do
          not executable_matches?(executable, expected_executable) ->
            :identity_mismatch

          is_binary(expected_hash) and expected_hash != "" ->
            case verify_hash(executable, expected_hash) do
              :verified -> verify_start(pid, expected_start)
              result -> result
            end

          true ->
            verify_start(pid, expected_start)
        end

      :absent ->
        :absent

      {:error, result} ->
        result
    end
  rescue
    _ -> :observation_failed
  end

  def verify(_pid, _expected_executable, _expected_hash, _expected_start),
    do: :identity_mismatch

  def start_fingerprint(pid) when is_integer(pid) and pid > 1 do
    case :os.type() do
      {:unix, :linux} -> linux_start_fingerprint(pid)
      _ -> ps_start_fingerprint(pid)
    end
  rescue
    _ -> {:error, :observation_failed}
  end

  def start_fingerprint(_pid), do: {:error, :identity_mismatch}

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
    case tool_path(:lsof) do
      nil ->
        {:error, :observation_failed}

      lsof ->
        case Command.run(lsof, ["-a", "-p", Integer.to_string(pid), "-d", "txt", "-Fn"]) do
          {:ok, output, 0} -> parse_lsof(output)
          {:ok, output, _status} -> classify_command_output(output)
          {:error, _reason, _output} -> {:error, :observation_failed}
        end
    end
  end

  defp ps_executable(pid) do
    case tool_path(:ps) do
      nil ->
        {:error, :observation_failed}

      ps ->
        case Command.run(ps, ["-o", "pid=,comm=", "-p", Integer.to_string(pid)]) do
          {:ok, output, 0} ->
            case parse_ps(output, pid) do
              {:ok, executable} -> {:ok, executable}
              :absent -> :absent
              :invalid -> {:error, :observation_failed}
            end

          {:ok, output, _status} ->
            classify_command_output(output)

          {:error, _reason, _output} ->
            {:error, :observation_failed}
        end
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

  defp verify_start(_pid, nil), do: :verified
  defp verify_start(_pid, ""), do: :verified

  defp verify_start(pid, expected) when is_binary(expected) do
    case start_fingerprint(pid) do
      {:ok, ^expected} -> :verified
      {:ok, _actual} -> :identity_mismatch
      :absent -> :absent
      {:error, reason} -> reason
    end
  end

  defp verify_start(_pid, _expected), do: :identity_mismatch

  defp linux_start_fingerprint(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, contents} ->
        contents = String.trim(contents)

        case Regex.run(~r/\A\d+ \(.*\) (.*)\z/, contents, capture: :all_but_first) do
          [fields] ->
            case Enum.at(String.split(fields), 19) do
              value when is_binary(value) and value != "" -> {:ok, "linux:" <> value}
              _ -> {:error, :observation_failed}
            end

          _ ->
            {:error, :observation_failed}
        end

      {:error, reason} ->
        case classify_file_error(reason) do
          {:error, _} = error -> error
          result -> result
        end
    end
  end

  defp ps_start_fingerprint(pid) do
    case tool_path(:ps) do
      nil ->
        {:error, :observation_failed}

      ps ->
        case Command.run(ps, ["-o", "lstart=", "-p", Integer.to_string(pid)]) do
          {:ok, output, 0} ->
            case String.trim(output) do
              "" -> :absent
              value -> {:ok, "ps:" <> value}
            end

          {:ok, output, _status} ->
            classify_command_output(output)

          {:error, _reason, _output} ->
            {:error, :observation_failed}
        end
    end
  end

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

    case tool_path(:realpath) do
      nil ->
        expanded

      realpath ->
        case Command.run(realpath, [expanded]) do
          {:ok, output, 0} -> String.trim(output)
          _ -> expanded
        end
    end
  rescue
    _ -> Path.expand(path)
  end

  defp verify_hash(path, expected) when is_binary(path) do
    case tool_path(:shasum) do
      nil ->
        :observation_failed

      shasum ->
        case Command.run(shasum, ["-a", "256", path]) do
          {:ok, output, 0} ->
            case String.split(String.trim(output)) do
              [actual | _] -> if actual == expected, do: :verified, else: :identity_mismatch
              _ -> :observation_failed
            end

          {:ok, output, _status} ->
            if String.contains?(String.downcase(output), "operation not permitted"),
              do: :permission_unknown,
              else: :observation_failed

          {:error, _reason, _output} ->
            :observation_failed
        end
    end
  rescue
    _ -> :observation_failed
  end

  defp tool_path(tool) do
    @tool_paths
    |> Map.fetch!(tool)
    |> Enum.find(&File.regular?/1)
  end
end
