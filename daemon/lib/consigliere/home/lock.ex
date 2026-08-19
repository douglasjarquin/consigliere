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
        {:ok, %{socket_path: socket_path, listen_socket: listen_socket}}

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
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket_path}, backlog: 1])
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.socket_path)
    :ok
  end
end
