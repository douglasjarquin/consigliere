defmodule Consigliere.CLIMainTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Consigliere.CLI
  alias Consigliere.Home

  test "cs --help and unknown command print usage" do
    out = capture_io(fn -> CLI.main(["--help"]) end)
    assert out =~ "cs ping"
    assert out =~ "csd start"

    err =
      capture_io(:stderr, fn ->
        capture_io(fn -> CLI.main(["nope"]) end)
      end)

    assert err =~ "unknown command"
  end

  test "cs ping talks to the live privileged socket" do
    output = capture_io(fn -> CLI.main(["ping"]) end)
    assert output =~ "pong"
  end

  test "cs doctor reports CS_HOME" do
    output = capture_io(fn -> CLI.main(["doctor"]) end)
    assert output =~ "home:"
    assert output =~ Home.dir()
  end
end
