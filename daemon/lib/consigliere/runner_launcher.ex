defmodule Consigliere.RunnerLauncher do
  @moduledoc """
  Spike C: launches the daemon-independent `cs-runner` OS process and speaks
  its NDJSON control-channel protocol as the client (the daemon side).

  This is a spike-scoped helper, not a supervised OTP process: it exists to
  prove out the Elixir <-> cs-runner protocol boundary described in
  docs/protocols/runner.md, ahead of building the real supervised launcher.
  """

  defstruct [
    :port,
    :socket,
    :manifest_path,
    :control_socket_path,
    :harness_pid,
    :runner_os_pid,
    :pgid
  ]

  def cs_runner_source_dir do
    Path.expand("../../../runner/cs-runner", __DIR__)
  end

  def ensure_binary! do
    packaged = Path.join(:code.priv_dir(:consigliere_daemon), "cs-runner")

    cond do
      File.exists?(packaged) ->
        packaged

      true ->
        path = cs_runner_bin_path()
        source_dir = cs_runner_source_dir()

        if source_newer_than_binary?(source_dir, path) do
          {_, 0} = System.cmd("go", ["build", "-o", "cs-runner", "."], cd: source_dir)
        end

        path
    end
  end

  def cs_runner_bin_path do
    packaged = Path.join(:code.priv_dir(:consigliere_daemon), "cs-runner")

    if File.exists?(packaged) do
      packaged
    else
      Path.join(cs_runner_source_dir(), "cs-runner")
    end
  end

  defp source_newer_than_binary?(source_dir, binary_path) do
    not File.exists?(binary_path) or
      Enum.any?(Path.wildcard(Path.join(source_dir, "*.go")), fn file ->
        File.stat!(file).mtime >= File.stat!(binary_path).mtime
      end)
  end

  def launch(opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    mission_id = Keyword.fetch!(opts, :mission_id)
    fencing_token = Keyword.fetch!(opts, :fencing_token)
    manifest_path = Keyword.fetch!(opts, :manifest_path)
    control_socket_path = Keyword.fetch!(opts, :control_socket_path)
    harness_command = Keyword.fetch!(opts, :harness_command)

    args =
      [
        "--attempt-id",
        attempt_id,
        "--mission-id",
        mission_id,
        "--fencing-token",
        fencing_token,
        "--manifest",
        manifest_path,
        "--control-socket",
        control_socket_path,
        "--"
      ] ++ harness_command

    port =
      Port.open({:spawn_executable, cs_runner_bin_path()}, [
        :binary,
        :exit_status,
        args: args,
        env: Keyword.get(opts, :env, [])
      ])

    with :ok <- wait_for_file(control_socket_path, 5_000),
         {:ok, socket} <-
           :gen_tcp.connect({:local, control_socket_path}, 0, [
             :binary,
             active: false,
             packet: :line
           ]),
         {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, %{"type" => "runner_started"} = started} <- JSON.decode(String.trim(line)) do
      {:ok,
       %__MODULE__{
         port: port,
         socket: socket,
         manifest_path: manifest_path,
         control_socket_path: control_socket_path,
         harness_pid: started["harness_pid"],
         runner_os_pid: started["runner_pid"],
         pgid: started["pgid"]
       }}
    else
      {:ok, %{"type" => other}} -> {:error, {:unexpected_message, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel(%__MODULE__{socket: socket}) do
    send_json(socket, %{"type" => "cancel"})
  end

  def recv(%__MODULE__{socket: socket}, timeout) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
      JSON.decode(String.trim(line))
    end
  end

  def recv_until(session, type, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_recv_until(session, type, deadline)
  end

  defp do_recv_until(session, type, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case recv(session, remaining) do
        {:ok, %{"type" => ^type} = msg} ->
          {:ok, msg}

        {:ok, %{"type" => skip}} when skip in ["stdout_chunk", "stderr_chunk"] ->
          do_recv_until(session, type, deadline)

        other ->
          other
      end
    end
  end

  defp send_json(socket, msg) do
    :gen_tcp.send(socket, JSON.encode!(msg) <> "\n")
  end

  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_file(path, deadline)
  end

  defp do_wait_for_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :control_socket_timeout}

      true ->
        Process.sleep(20)
        do_wait_for_file(path, deadline)
    end
  end
end
