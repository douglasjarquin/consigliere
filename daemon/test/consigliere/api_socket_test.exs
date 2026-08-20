defmodule Consigliere.API.SocketTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Client
  alias Consigliere.API.Listener
  alias Consigliere.Fixtures
  alias Consigliere.Home

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  test "a live api.sock round-trips ping" do
    resp = Client.request("ping")
    assert resp["ok"] == true
    assert resp["payload"]["pong"] == true
  end

  test "boss.sock remains the lock probe and is still live" do
    home = Path.join(System.tmp_dir!(), "consigliere-daemon-test-home")
    assert Home.socket_status(home) == :live
    refute Listener.socket_path() == Home.boss_socket_path(home)
  end

  test "a crashed connection worker does not take down the listener" do
    path = Listener.socket_path()

    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], 2_000)

    children = DynamicSupervisor.which_children(Consigliere.API.ConnectionSupervisor)
    pids = for {_, pid, :worker, _} <- children, is_pid(pid), do: pid
    Enum.each(pids, &Process.exit(&1, :kill))
    :gen_tcp.close(sock)

    Process.sleep(50)
    resp = Client.request("ping")
    assert resp["ok"] == true
  end

  test "create over the socket persists a Mission" do
    resp =
      Client.request("mission.create", %{
        "objective" => "from-socket",
        "scope" => "s",
        "acceptance_criteria" => "a"
      })

    assert resp["ok"] == true
    id = resp["payload"]["id"]
    got = Client.request("mission.get", %{"mission_id" => id})
    assert got["payload"]["objective"] == "from-socket"
    assert got["payload"]["phase"] == "draft"
  end
end
