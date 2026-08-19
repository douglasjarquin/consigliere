defmodule Consigliere.Home.Lock do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Consigliere.Home.dir()
    Consigliere.Home.ensure_dir!(home)
    socket_path = Consigliere.Home.boss_socket_path(home)

    case claim(socket_path) do
      {:ok, listen_socket} ->
        acceptor = spawn_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{socket_path: socket_path, listen_socket: listen_socket, acceptor: acceptor}}

      :already_running ->
        {:stop, :already_running}

      {:error, reason} ->
        {:stop, {:bind_failed, reason}}
    end
  end

  defp claim(socket_path) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :already_running

      {:error, _not_live} ->
        File.rm(socket_path)
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}, backlog: 128])
    end
  end

  # A status probe (ours or anyone else's) just connects and disconnects --
  # nothing ever calls accept/1 on the other end, so an unaccepted
  # connection sits in the kernel's backlog until something drains it.
  # With no acceptor, that queue fills after a handful of probes and every
  # later connect gets refused, making a perfectly live lock look :stale --
  # which would make the next boot delete a live daemon's socket file.
  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        accept_loop(listen_socket)
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.socket_path)
    :ok
  end
end
