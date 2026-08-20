defmodule Consigliere.Home.Lock do
  @moduledoc """
  Exclusive CS_HOME ownership via fcntl flock. Socket files are liveness
  probes only; they are never unlinked until this process holds the lock.

  Mix releases replace PATH with erts/bin. Python and flock are found
  on a fixed Unix path. The lock helper is compiled into the BEAM so a
  missing priv copy cannot fail boot.
  """

  use GenServer

  alias Consigliere.Home

  @lock_script_path Path.expand("../../../priv/home_lock.py", __DIR__)
  @external_resource @lock_script_path
  @lock_script File.read!(@lock_script_path)
  @helper_path "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/opt/python@3/bin"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Home.dir()
    Home.ensure_dir!(home)

    case acquire_flock(home) do
      {:ok, port} ->
        case bind_probe(Home.boss_socket_path(home)) do
          {:ok, listen} ->
            acceptor = spawn_link(fn -> accept_loop(listen) end)
            {:ok, %{home: home, port: port, listen_socket: listen, acceptor: acceptor}}

          {:error, reason} ->
            close_port(port)
            {:stop, {:bind_failed, reason}}
        end

      :already_running ->
        {:stop, :already_running}

      {:error, reason} ->
        {:stop, {:lock_failed, reason}}
    end
  end

  # A just-exited eval VM can leave the helper alive for one poll interval.
  # Refuse immediately if a live probe is already bound.
  @lock_retry_times 20
  @lock_retry_ms 50

  defp acquire_flock(home, remaining \\ @lock_retry_times) do
    path = Home.lock_path(home)

    result = acquire_once(home, path)

    case result do
      :already_running ->
        if remaining > 0 and Home.socket_status(home) != :live do
          Process.sleep(@lock_retry_ms)
          acquire_flock(home, remaining - 1)
        else
          :already_running
        end

      other ->
        other
    end
  end

  defp acquire_once(home, path) do
    cond do
      python = python_executable() ->
        acquire_python(python, materialize_script!(home), path)

      flock = helper_executable("flock") ->
        acquire_util_linux_flock(flock, path)

      true ->
        {:error, :python3_required}
    end
  end

  defp acquire_python(python, script, path) do
    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :hide,
        args: [script, path]
      ])

    await_lock(port)
  end

  defp acquire_util_linux_flock(flock, path) do
    port =
      Port.open({:spawn_executable, flock}, [
        :binary,
        :exit_status,
        :hide,
        args: [
          "--nonblock",
          "--exclusive",
          path,
          "--command",
          "/bin/sh -c '/bin/echo ok; exec /bin/cat'"
        ]
      ])

    await_lock(port)
  end

  defp await_lock(port) do
    receive do
      {^port, {:data, data}} ->
        case String.trim(to_string(data)) do
          "ok" -> {:ok, port}
          "locked" -> close_port(port, :already_running)
          _ -> close_port(port, {:error, {:unexpected, data}})
        end

      {^port, {:exit_status, status}} when status in [1, 2] ->
        :already_running

      {^port, {:exit_status, status}} ->
        {:error, {:lock_exit, status}}
    after
      2_000 ->
        close_port(port, {:error, :timeout})
    end
  end

  defp materialize_script!(home) do
    dest = Path.join(home, "bin/home_lock.py")
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, @lock_script)
    File.chmod!(dest, 0o700)
    dest
  end

  defp python_executable do
    helper_executable("python3") || helper_executable("python")
  end

  defp helper_executable(name) do
    (@helper_path <> ":" <> (System.get_env("PATH") || ""))
    |> String.split(":", trim: true)
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, name)

      if File.exists?(path) do
        path
      end
    end)
  end

  defp close_port(port, result) do
    close_port(port)
    result
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp bind_probe(socket_path) do
    File.rm(socket_path)

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}, backlog: 128]) do
      {:ok, _listen} = ok ->
        _ = File.chmod(socket_path, 0o600)
        ok

      other ->
        other
    end
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(listen_socket)
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state[:listen_socket], do: :gen_tcp.close(state.listen_socket)
    if state[:port], do: close_port(state.port)
    if state[:home], do: File.rm(Home.boss_socket_path(state.home))
    :ok
  end
end
