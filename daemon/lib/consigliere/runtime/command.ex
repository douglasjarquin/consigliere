defmodule Consigliere.Runtime.Command do
  @moduledoc false

  @max_output 65_536

  def run(executable, args, opts \\ [])

  def run(executable, args, opts) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 2_000)
    max_output = Keyword.get(opts, :max_output, @max_output)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    collect(port, System.monotonic_time(:millisecond) + timeout_ms, max_output, [])
  rescue
    _ -> {:error, :spawn_failed, ""}
  end

  def run(_executable, _args, _opts), do: {:error, :invalid_command, ""}

  defp collect(port, deadline, max_output, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_port(port)
      {:error, :timeout, IO.iodata_to_binary(acc)}
    else
      receive do
        {^port, {:data, data}} ->
          next = [acc, data]

          if IO.iodata_length(next) > max_output do
            close_port(port)
            {:error, :output_too_large, IO.iodata_to_binary(next)}
          else
            collect(port, deadline, max_output, next)
          end

        {^port, {:exit_status, exit_status}} ->
          {:ok, IO.iodata_to_binary(acc), exit_status}
      after
        remaining ->
          close_port(port)
          {:error, :timeout, IO.iodata_to_binary(acc)}
      end
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
