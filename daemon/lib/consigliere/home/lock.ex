defmodule Consigliere.Home.Lock do
  @moduledoc """
  Exclusive CS_HOME ownership via fcntl flock. Socket files are liveness
  probes only; they are never unlinked until this process holds the lock.
  """

  use GenServer

  alias Consigliere.Home

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Home.dir()
    Home.ensure_dir!(home)

    case acquire_flock(Home.lock_path(home)) do
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

  @python_candidates [
    "python3",
    "python",
    "/usr/bin/python3",
    "/usr/bin/python",
    "/usr/local/bin/python3",
    "/opt/homebrew/bin/python3"
  ]

  defp acquire_flock(path) do
    python = python_executable()
    script = Path.join(:code.priv_dir(:consigliere_daemon), "home_lock.py")

    if python && File.exists?(script) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          :hide,
          args: [script, path]
        ])

      receive do
        {^port, {:data, data}} ->
          case String.trim(to_string(data)) do
            "ok" -> {:ok, port}
            "locked" -> close_port(port, :already_running)
            _ -> close_port(port, {:error, {:unexpected, data}})
          end

        {^port, {:exit_status, 2}} ->
          :already_running

        {^port, {:exit_status, status}} ->
          {:error, {:lock_exit, status}}
      after
        2_000 ->
          close_port(port, {:error, :timeout})
      end
    else
      {:error, :python3_required}
    end
  end

  defp python_executable do
    Enum.find_value(@python_candidates, fn name ->
      if String.starts_with?(name, "/") do
        if File.exists?(name), do: name
      else
        System.find_executable(name)
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
