defmodule Consigliere.TerminationTest do
  use ExUnit.Case, async: false

  alias Consigliere.Fixtures
  alias Consigliere.Attempts.Attempt
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Termination

  defmodule FakeRunner do
    use GenServer

    def start_link(attempt_id), do: GenServer.start_link(__MODULE__, attempt_id)

    @impl true
    def init(attempt_id) do
      Registry.register(Consigliere.Registry, {:runner, attempt_id}, nil)
      {:ok, %{}}
    end

    @impl true
    def handle_call(:cancel, _from, state), do: {:reply, :ok, state}
  end

  setup do
    Fixtures.reset_phase1_tables!()
    home = Path.join(System.tmp_dir!(), "cs-termination-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("CS_HOME")
    System.put_env("CS_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("CS_HOME", previous_home),
        else: System.delete_env("CS_HOME")

      File.rm_rf(home)
    end)

    :ok
  end

  test "does not signal a persisted pgid without verified live inventory" do
    {port, pgid} = Consigliere.ProcessHelpers.spawn_session_leader()
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission, %{status: "running", pgid: pgid})

    assert {:error, :death_unverified} = Termination.finalize(attempt.id, "canceled")
    assert ProcessGroup.alive?(pgid)
  end

  test "delivery leaves a live runner terminating until reconciliation verifies death" do
    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission, %{status: "terminating"})
    {:ok, runner} = FakeRunner.start_link(attempt.id)

    on_exit(fn ->
      if Process.alive?(runner), do: GenServer.stop(runner)
    end)

    item = %OutboxItem{
      payload: %{
        "attempt_id" => attempt.id,
        "mission_id" => mission.id,
        "cause" => "canceled"
      }
    }

    assert :ok = Termination.deliver(item)
    assert Repo.get!(Attempt, attempt.id).status == "terminating"
  end
end
