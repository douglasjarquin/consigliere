defmodule Consigliere.API.Connection do
  @moduledoc false

  def child_spec(socket) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [socket]},
      restart: :temporary
    }
  end

  def start_link(socket) do
    Task.start_link(fn ->
      receive do
        :go -> loop(socket)
      after
        5_000 -> :gen_tcp.close(socket)
      end
    end)
  end

  defp loop(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, line} ->
        reply = Consigliere.API.Protocol.handle(line)
        _ = :gen_tcp.send(socket, reply <> "\n")
        loop(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
        :ok
    end
  end
end
