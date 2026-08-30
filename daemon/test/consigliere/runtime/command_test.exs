defmodule Consigliere.Runtime.CommandTest do
  use ExUnit.Case, async: false

  alias Consigliere.Runtime.Command

  test "a hung native observer returns within its caller deadline" do
    executable = System.find_executable("sleep") || "/bin/sleep"
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout, _output} =
             Command.run(executable, ["30"], timeout_ms: 50)

    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end
end
