defmodule Consigliere.ApplicationBootResultTest do
  use ExUnit.Case, async: true

  alias Consigliere.Home

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "cs-home-boot-result-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "a real (non-forced) boot failure is recorded to last_error.log", %{home: home} do
    reason = {:shutdown, {:failed_to_start_child, SomeChild, :boom}}

    assert {:error, ^reason} = Consigliere.Application.record_boot_result({:error, reason}, home)

    assert Home.last_error(home) =~ "boom"
  end

  test "an already_running refusal is not recorded as a startup failure", %{home: home} do
    reason = {:shutdown, {:failed_to_start_child, Consigliere.Home.Lock, :already_running}}

    assert {:error, ^reason} = Consigliere.Application.record_boot_result({:error, reason}, home)

    assert Home.last_error(home) == nil
  end

  test "an already_running refusal does not clobber a genuinely recorded prior failure", %{
    home: home
  } do
    Home.record_error!(home, "a real prior failure worth keeping")
    reason = {:shutdown, {:failed_to_start_child, Consigliere.Home.Lock, :already_running}}

    Consigliere.Application.record_boot_result({:error, reason}, home)

    assert Home.last_error(home) == "a real prior failure worth keeping"
  end

  test "a successful boot clears any previously recorded failure", %{home: home} do
    Home.record_error!(home, "stale failure from a previous crash")

    assert {:ok, :fake_pid} =
             Consigliere.Application.record_boot_result({:ok, :fake_pid}, home)

    assert Home.last_error(home) == nil
  end
end
