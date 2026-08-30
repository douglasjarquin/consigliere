defmodule Consigliere.ProjectVerificationsCommandTest do
  use ExUnit.Case, async: false

  alias Consigliere.ProjectVerifications.Command

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "cs-verification-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "passes literal argv without allowing shell interpolation", %{workspace: workspace} do
    marker = Path.join(workspace, "injected")

    assert %{outcome: "passed", output_bytes: bytes} =
             Command.run(["printf", "safe; touch #{marker}"], workspace)

    assert bytes == byte_size("safe; touch #{marker}")
    refute File.exists?(marker)
  end

  test "returns a bounded timeout outcome", %{workspace: workspace} do
    assert %{
             outcome: "infrastructure_error",
             timed_out: true,
             error_code: "timeout"
           } = Command.run(["sleep", "1"], workspace, timeout_ms: 25, total_timeout_ms: 100)
  end

  test "returns a bounded output outcome", %{workspace: workspace} do
    assert %{
             outcome: "infrastructure_error",
             timed_out: false,
             error_code: "output_too_large",
             output_bytes: output_bytes
           } = Command.run(["seq", "1", "30000"], workspace, total_timeout_ms: 2_000)

    assert output_bytes <= 65_536
  end
end
