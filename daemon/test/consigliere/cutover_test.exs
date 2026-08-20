defmodule Consigliere.CutoverTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Consigliere.CLI

  test "the cutover runbook exists and is the Phase 8 checklist, not shadow mode" do
    path = CLI.runbook_path()
    assert File.exists?(path), "missing #{path}"
    body = File.read!(path)

    assert body =~ "Do not build full shadow mode"
    assert body =~ "Dual dispatch"

    for step <- [
          "Choose one noncritical Project",
          "Pause legacy dispatch",
          "Confirm no legacy Agent is actively writing",
          "Classify existing legacy tasks",
          "Import Project repository identity",
          "Create the trusted mirror",
          "Reconcile existing branches and PRs",
          "Enable the new internal Mission backlog",
          "Run a controlled Mission",
          "Test Question flow",
          "Test AFK return",
          "Test daemon restart",
          "Test a Made decision",
          "Test exact-SHA delivery",
          "Document incidents and corrections",
          "Run multiple real Missions before expanding"
        ] do
      assert body =~ step, "runbook missing step: #{step}"
    end
  end

  test "cs cutover prints the runbook" do
    output = capture_io(fn -> CLI.cutover() end)
    assert output =~ "Cutover runbook"
    assert output =~ "Do not build full shadow mode"
    assert output =~ "Test exact-SHA delivery"
  end
end
