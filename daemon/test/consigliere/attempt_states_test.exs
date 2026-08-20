defmodule Consigliere.AttemptStatesTest do
  use ExUnit.Case, async: true

  alias Consigliere.AttemptStates

  test "occupying, recoverable, process-may-exist, and terminal sets are disjoint where required" do
    assert AttemptStates.occupying() -- AttemptStates.terminal() == AttemptStates.occupying()
    assert AttemptStates.terminal() -- AttemptStates.occupying() == AttemptStates.terminal()
    assert AttemptStates.recoverable() -- AttemptStates.occupying() == []
    assert "planned" in AttemptStates.occupying()
    assert "planned" in AttemptStates.recoverable()
    refute "planned" in AttemptStates.process_may_exist()
    assert "starting" in AttemptStates.process_may_exist()
    assert "checkpointed" in AttemptStates.process_may_exist()
    refute AttemptStates.terminal?("running")
    assert AttemptStates.terminal?("lost")
  end

  test "every Attempt schema status is classified exactly once as occupying or terminal or checkpointed" do
    for status <- Consigliere.Attempts.Attempt.statuses() do
      occupying? = AttemptStates.occupying?(status)
      terminal? = AttemptStates.terminal?(status)
      checkpointed? = status == "checkpointed"

      assert occupying? or terminal? or checkpointed?
      refute occupying? and terminal?
    end
  end
end
