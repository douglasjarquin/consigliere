defmodule Consigliere.ApplicationChildrenTest do
  use ExUnit.Case, async: true

  alias Consigliere.Application, as: App
  alias Consigliere.Home.Lock

  test "eval, rpc, and remote do not take CS_HOME or bind daemon sockets" do
    for command <- ["eval", "rpc", "remote"] do
      refute Lock in App.children(command),
             "#{command} must not supervise Home.Lock"
    end
  end

  test "start, daemon, and mix boot take CS_HOME" do
    for command <- ["start", "start_iex", "daemon", "daemon_iex", nil] do
      assert Lock in App.children(command),
             "#{inspect(command)} must supervise Home.Lock"
    end
  end

  test "V0 boot does not supervise visible notification delivery" do
    refute Consigliere.NotificationDispatcher in App.children(nil)
  end

  test "boot starts runner identity registries before reconciliation" do
    children = App.children(nil)

    registry_index =
      Enum.find_index(children, fn
        {Registry, opts} -> Keyword.get(opts, :name) == Consigliere.Registry
        _ -> false
      end)

    runner_index = Enum.find_index(children, &(&1 == Consigliere.RunnerDynamicSupervisor))
    reconciler_index = Enum.find_index(children, &(&1 == Consigliere.Reconciler))

    assert registry_index < reconciler_index
    assert runner_index < reconciler_index
  end
end
