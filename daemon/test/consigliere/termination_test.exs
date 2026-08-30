defmodule Consigliere.TerminationTest do
  use ExUnit.Case, async: false

  alias Consigliere.Fixtures
  alias Consigliere.ProcessGroup
  alias Consigliere.Termination

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
end
