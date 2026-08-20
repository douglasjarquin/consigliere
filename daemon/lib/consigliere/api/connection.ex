defmodule Consigliere.API.Connection do
  @moduledoc false

  def child_spec({socket, bound}) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [socket, bound]},
      restart: :temporary
    }
  end

  def start_link(socket, bound) do
    Task.start_link(fn ->
      receive do
        :go -> loop(socket, bound)
      after
        5_000 -> :gen_tcp.close(socket)
      end
    end)
  end

  @max_frame 65_536

  defp loop(socket, bound) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, line} when byte_size(line) > @max_frame ->
        reply =
          JSON.encode!(%{
            "v" => 1,
            "ok" => false,
            "error" => %{"code" => "payload_too_large", "reason" => "frame exceeds #{@max_frame}"}
          })

        _ = :gen_tcp.send(socket, reply <> "\n")
        :gen_tcp.close(socket)

      {:ok, line} ->
        reply = Consigliere.API.Protocol.handle(line, bound)
        _ = :gen_tcp.send(socket, reply <> "\n")
        loop(socket, bound)

      {:error, _} ->
        :gen_tcp.close(socket)
        :ok
    end
  end
end
