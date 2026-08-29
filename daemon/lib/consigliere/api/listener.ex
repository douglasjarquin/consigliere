defmodule Consigliere.API.Listener do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def socket_path(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> default_path(name)
      pid -> GenServer.call(pid, :socket_path)
    end
  end

  def privileged_socket_path, do: socket_path(Consigliere.API.PrivilegedListener)

  defp default_path(Consigliere.API.PrivilegedListener),
    do: Consigliere.Home.privileged_socket_path()

  defp default_path(_), do: Consigliere.Home.api_socket_path()

  @impl true
  def init(opts) do
    home = opts[:home] || Consigliere.Home.dir()
    which = Keyword.get(opts, :which, :api)
    Consigliere.Home.ensure_dir!(home)
    socket_path = path_for(which, home)
    bound = bound_for(which)

    case bind(socket_path) do
      {:ok, listen} ->
        _ = File.chmod(socket_path, 0o600)
        acceptor = spawn_link(fn -> accept_loop(listen, bound) end)
        {:ok, %{socket_path: socket_path, listen: listen, acceptor: acceptor, bound: bound}}

      {:error, reason} ->
        {:stop, {:bind_failed, reason}}
    end
  end

  defp path_for(:privileged, home), do: Consigliere.Home.privileged_socket_path(home)
  defp path_for(:api, home), do: Consigliere.Home.api_socket_path(home)

  defp bound_for(:privileged), do: :privileged
  defp bound_for(:api), do: :capability

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

        :gen_tcp.listen(0, [
          :binary,
          packet: :line,
          packet_size: Consigliere.V0.Limits.frame_bytes(),
          active: false,
          ifaddr: {:local, socket_path},
          backlog: 128
        ])
    end
  end

  defp accept_loop(listen, bound) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        spec = {Consigliere.API.Connection, {conn, bound}}

        case DynamicSupervisor.start_child(Consigliere.API.ConnectionSupervisor, spec) do
          {:ok, pid} ->
            :ok = :gen_tcp.controlling_process(conn, pid)
            send(pid, :go)

          {:error, _} ->
            :gen_tcp.close(conn)
        end

        accept_loop(listen, bound)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(listen, bound)
    end
  end
end
