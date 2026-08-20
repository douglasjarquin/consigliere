defmodule Consigliere.API.Client do
  @moduledoc false

  def request(op, payload \\ %{}, actor \\ %{"principal" => "boss"}, opts \\ []) do
    default_path =
      case actor["principal"] do
        "boss" -> Consigliere.API.Listener.privileged_socket_path()
        _ -> Consigliere.API.Listener.socket_path()
      end

    path = Keyword.get(opts, :socket_path, default_path)
    id = Keyword.get(opts, :id, "req-#{System.unique_integer([:positive])}")

    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], 2_000)

    try do
      body =
        JSON.encode!(
          %{
            "v" => Keyword.get(opts, :v, 1),
            "id" => id,
            "op" => op,
            "actor" => actor,
            "payload" => payload
          }
          |> maybe_secret(path)
        )

      :ok = :gen_tcp.send(sock, body <> "\n")
      {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
      {:ok, decoded} = JSON.decode(String.trim(line))
      decoded
    after
      :gen_tcp.close(sock)
    end
  end

  defp maybe_secret(map, path) do
    priv = Consigliere.API.Listener.privileged_socket_path()
    api = Consigliere.API.Listener.socket_path()

    cond do
      path == priv and get_in(map, ["actor", "principal"]) == "boss" ->
        Map.put(map, "secret", Consigliere.Home.ensure_boss_secret!())

      path == api and is_nil(map["capability"]) ->
        Map.put(map, "secret", Consigliere.Home.ensure_advisory_secret!())

      true ->
        map
    end
  end
end
