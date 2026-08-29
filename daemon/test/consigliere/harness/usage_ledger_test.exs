defmodule Consigliere.Harness.UsageLedgerTest do
  use ExUnit.Case, async: false

  alias Consigliere.Harness.UsageLedger

  test "records only bounded identity fields and token counters" do
    home = Path.join(System.tmp_dir!(), "cs-usage-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(home) end)

    identity = %{
      system: "consigliere",
      project_id: "project-1",
      mission_id: "mission-1",
      attempt_id: "attempt-1",
      session_id: "session-1",
      model: "gpt-5",
      effort: "high",
      cli_version: "codex 1.2.3",
      context_hash: String.duplicate("a", 64)
    }

    assert {:ok, :recorded} =
             UsageLedger.record(
               identity,
               %{
                 "input_tokens" => 10,
                 "output_tokens" => 20,
                 "cached_input_tokens" => 3,
                 "total_tokens" => 30,
                 "secret" => "must-not-be-written"
               },
               home
             )

    [row] =
      UsageLedger.path(home, "attempt-1")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert row["project_id"] == "project-1"
    assert row["session_id"] == "session-1"
    assert row["input_tokens"] == 10
    assert row["output_tokens"] == 20
    assert row["cached_input_tokens"] == 3
    assert row["total_tokens"] == 30
    refute Map.has_key?(row, "secret")
    refute File.read!(UsageLedger.path(home, "attempt-1")) =~ "must-not-be-written"
  end
end
