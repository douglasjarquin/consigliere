defmodule Consigliere.API.Client do
  @moduledoc false

  def request(op, payload \\ %{}, actor \\ %{"principal" => "boss"}, opts \\ []) do
    path = Keyword.get(opts, :socket_path, Consigliere.API.Listener.socket_path())
    id = Keyword.get(opts, :id, "req-#{System.unique_integer([:positive])}")

    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], 2_000)

    try do
      body =
        JSON.encode!(%{
          "v" => Keyword.get(opts, :v, 1),
          "id" => id,
          "op" => op,
          "actor" => actor,
          "payload" => payload
        })

      :ok = :gen_tcp.send(sock, body <> "\n")
      {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
      {:ok, decoded} = JSON.decode(String.trim(line))
      decoded
    after
      :gen_tcp.close(sock)
    end
  end
end
