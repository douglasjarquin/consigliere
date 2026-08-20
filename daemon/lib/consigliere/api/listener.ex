defmodule Consigliere.API.Listener do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def socket_path do
    case Process.whereis(__MODULE__) do
      nil -> Consigliere.Home.api_socket_path()
      pid -> GenServer.call(pid, :socket_path)
    end
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Consigliere.Home.dir()
    Consigliere.Home.ensure_dir!(home)
    socket_path = Consigliere.Home.api_socket_path(home)

    case bind(socket_path) do
      {:ok, listen} ->
        acceptor = spawn_link(fn -> accept_loop(listen) end)
        {:ok, %{socket_path: socket_path, listen: listen, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:bind_failed, reason}}
    end
  end

  @impl true
  def handle_call(:socket_path, _from, state), do: {:reply, state.socket_path, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.socket_path)
    :ok
  end

  defp bind(socket_path) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        {:error, :already_running}

      {:error, _} ->
        File.rm(socket_path)
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, socket_path}, backlog: 128])
    end
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        spec = {Consigliere.API.Connection, conn}

        case DynamicSupervisor.start_child(Consigliere.API.ConnectionSupervisor, spec) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(conn, pid)
            send(pid, :go)

          {:error, _} ->
            :gen_tcp.close(conn)
        end

        accept_loop(listen)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(listen)
    end
  end
end
