defmodule Consigliere.Home.Lock do
  @moduledoc """
  Exclusive CS_HOME ownership by binding boss.sock.

  A live instance answers connect(). A dead instance leaves a stale
  socket file; that file is unlinked only after connect() fails.

  Mix release start.boot and elixir start_cli can both start the OTP
  app. The same home reuses one lock process.
  """

  use GenServer

  require Logger

  alias Consigliere.Home

  def start_link(opts \\ []) do
    home = opts[:home] || Home.dir()
    name = {:global, {__MODULE__, Path.expand(home)}}

    case GenServer.start_link(__MODULE__, Keyword.put(opts, :home, home), name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @impl true
  def init(opts) do
    home = opts[:home] || Home.dir()
    Home.ensure_dir!(home)

    case bind_exclusive(Home.boss_socket_path(home)) do
      {:ok, listen} ->
        acceptor = spawn_link(fn -> accept_loop(listen) end)
        {:ok, %{home: home, listen_socket: listen, acceptor: acceptor}}

      :already_running ->
        {:stop, :already_running}

      {:error, reason} ->
        {:stop, {:bind_failed, reason}}
    end
  end

  defp bind_exclusive(socket_path) do
    case Home.probe(socket_path) do
      :live ->
        :already_running

      probe ->
        File.rm(socket_path)

        case listen_local(socket_path) do
          {:ok, listen} ->
            _ = File.chmod(socket_path, 0o600)
            {:ok, listen}

          {:error, :eaddrinuse} ->
            File.rm(socket_path)

            case listen_local(socket_path) do
              {:ok, listen} ->
                _ = File.chmod(socket_path, 0o600)
                {:ok, listen}

              {:error, :eaddrinuse} ->
                :already_running

              other ->
                other
            end

          other ->
            Logger.warning(
              "home lock listen failed path=#{socket_path} probe=#{inspect(probe)} result=#{inspect(other)}"
            )

            other
        end
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
    if state[:listen_socket], do: :gen_tcp.close(state.listen_socket)
    if state[:home], do: File.rm(Home.boss_socket_path(state.home))
    :ok
  end
end
