defmodule Consigliere.Home.LockOSTest do
  use ExUnit.Case, async: false

  alias Consigliere.Home
  alias Consigliere.Home.Lock

  test "exactly one of many probe processes can hold a home lock" do
    home = Path.join(System.tmp_dir!(), "cs-home-lock-os-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    lock_path = Home.lock_path(home)
    probe = Lock.probe_binary()
    n = 20

    ports =
      Enum.map(1..n, fn _ ->
        Port.open({:spawn_executable, probe}, [:binary, :exit_status, args: ["hold", lock_path]])
      end)

    results =
      Enum.map(ports, fn port ->
        receive do
          {^port, {:data, data}} -> String.trim(data)
          {^port, {:exit_status, 1}} -> "busy"
        after
          3_000 -> "timeout"
        end
      end)

    Enum.each(ports, fn port ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    assert Enum.count(results, &(&1 == "held")) == 1
    assert Enum.count(results, &(&1 == "busy")) == n - 1
  end
end
