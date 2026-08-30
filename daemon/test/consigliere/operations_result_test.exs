defmodule Consigliere.OperationsResultTest do
  use ExUnit.Case, async: true

  test "accepts latest as a daemon-resolved terminal sequence" do
    payload = %{
      "attempt_id" => "attempt-1",
      "mission_id" => "mission-1",
      "workspace_id" => "workspace-1",
      "workspace_generation" => "lease-1",
      "base_sha" => String.duplicate("a", 40),
      "fencing_generation" => "fence-1",
      "result_sha" => String.duplicate("b", 40),
      "result_kind" => "completed",
      "terminal_sequence" => "latest"
    }

    assert :ok = Consigliere.Operations.validate("attempt.complete", payload)
  end

  test "rejects an arbitrary terminal sequence string" do
    payload = %{
      "attempt_id" => "attempt-1",
      "mission_id" => "mission-1",
      "workspace_id" => "workspace-1",
      "workspace_generation" => "lease-1",
      "base_sha" => String.duplicate("a", 40),
      "fencing_generation" => "fence-1",
      "result_sha" => String.duplicate("b", 40),
      "result_kind" => "completed",
      "terminal_sequence" => "future"
    }

    assert {:error, "terminal_sequence must be positive or latest"} =
             Consigliere.Operations.validate("attempt.complete", payload)
  end
end
