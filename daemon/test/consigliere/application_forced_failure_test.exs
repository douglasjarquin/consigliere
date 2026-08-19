defmodule Consigliere.ApplicationForcedFailureTest do
  use ExUnit.Case, async: false

  alias Consigliere.Home

  setup do
    home =
      Path.join(System.tmp_dir!(), "cs-home-forced-failure-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "start/2 fails fast and records the reason when CS_FORCE_STARTUP_FAILURE is set", %{
    home: home
  } do
    System.put_env("CS_HOME", home)
    System.put_env("CS_FORCE_STARTUP_FAILURE", "simulated disk full")

    on_exit(fn ->
      System.delete_env("CS_HOME")
      System.delete_env("CS_FORCE_STARTUP_FAILURE")
    end)

    assert {:error, {:forced_startup_failure, "simulated disk full"}} =
             Consigliere.Application.start(:normal, [])

    assert Home.last_error(home) == "simulated disk full"
  end
end
