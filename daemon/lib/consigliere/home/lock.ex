defmodule Consigliere.Home.Lock do
  @moduledoc """
  Exclusive CS_HOME ownership via a kernel fcntl lock.

  The lock file descriptor lives in this BEAM process so crash or
  SIGKILL releases it. Socket files are diagnostic only and are cleaned
  only after the kernel lock is held.
  """

  use GenServer

  require Logger

  alias Consigliere.Home
  alias Consigliere.Home.Lock.NIF

  def start_link(opts \\ []) do
    home = opts[:home] || Home.dir()
    name = {:global, {__MODULE__, Path.expand(home)}}

    case GenServer.start_link(__MODULE__, Keyword.put(opts, :home, home), name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def probe_binary do
    Path.join(:code.priv_dir(:consigliere_daemon), "cs_lock_probe")
  end

  def with_lock(home \\ Home.dir(), fun) when is_function(fun, 0) do
    home = Path.expand(home)

    case :global.whereis_name({__MODULE__, home}) do
      pid when is_pid(pid) ->
        {:ok, fun.()}

      :undefined ->
        Home.prepare_root!(home)

        case NIF.acquire(Home.lock_path(home)) do
          {:ok, lock} ->
            try do
              {:ok, fun.()}
            after
              NIF.release(lock)
            end

          {:error, :busy} ->
            {:error, :already_running}

          {:error, reason} ->
            {:error, {:lock_failed, reason}}
        end
    end
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Home.dir()
    Home.prepare_root!(home)

    case NIF.acquire(Home.lock_path(home)) do
      {:ok, lock} ->
        Home.ensure_dir!(home)
        Home.write_owner!(home)
        Home.ensure_secrets!(home)
        bind_probe_socket(home, lock)

      {:error, :busy} ->
        {:stop, :already_running}

      {:error, reason} ->
        {:stop, {:lock_failed, reason}}
    end
  end

  defp bind_probe_socket(home, lock) do
    socket_path = Home.boss_socket_path(home)
    File.rm(socket_path)

    case listen_local(socket_path) do
      {:ok, listen} ->
        _ = File.chmod(socket_path, 0o600)
        acceptor = spawn_link(fn -> accept_loop(listen) end)
        {:ok, %{home: home, lock: lock, listen_socket: listen, acceptor: acceptor}}

      {:error, :eaddrinuse} ->
        {:stop, {:bind_failed, :eaddrinuse}}

      other ->
        Logger.warning("home lock listen failed path=#{socket_path} result=#{inspect(other)}")
        {:stop, {:bind_failed, other}}
    end
  end

  defp listen_local(socket_path) do
    :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}, backlog: 128])
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
    if is_map(state) do
      if state[:listen_socket], do: :gen_tcp.close(state.listen_socket)
      if state[:home], do: File.rm(Home.boss_socket_path(state.home))
      if state[:lock], do: NIF.release(state.lock)
      if state[:home], do: File.rm(Home.owner_path(state.home))
    end

    :ok
  end
end
