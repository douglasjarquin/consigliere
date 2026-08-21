defmodule Consigliere.Made.EventsTest do
  use ExUnit.Case, async: true

  alias Consigliere.Made.Events

  @identity %{
    run_id: "run-a",
    invocation_id: "inv-a",
    mission_id: "mission-a",
    gate_id: "gate-a",
    base_sha: "base",
    input_sha: "sha-a",
    policy_hash: "p1"
  }

  test "a complete identity-bound stream with matching sequence is accepted" do
    output = stream([started(1), completed(2, "passed")])
    assert {:ok, parsed} = Events.parse(output, @identity)
    assert parsed.terminal["outcome"] == "passed"
    assert length(parsed.events) == 2
  end

  test "findings are taken from stage.finding events" do
    finding = %{"fingerprint" => "fp-1", "description" => "needs a look", "path" => "a.ex"}
    output = stream([started(1), finding(2, finding), completed(3, "needs_decision")])
    assert {:ok, parsed} = Events.parse(output, @identity)
    assert hd(parsed.findings)["fingerprint"] == "fp-1"
  end

  test "missing terminal cannot pass" do
    assert {:error, :missing_terminal} = Events.parse(stream([started(1)]), @identity)
  end

  test "non-JSON lines cannot pass" do
    output = stream([started(1)]) <> "not-json\n" <> stream([completed(2, "passed")])
    assert {:error, :malformed} = Events.parse(output, @identity)
  end

  test "skipped sequence cannot pass" do
    output = stream([started(1), completed(3, "passed")])
    assert {:error, :sequence} = Events.parse(output, @identity)
  end

  test "wrong run identity cannot pass" do
    output = stream([started(1), completed(2, "passed")])
    assert {:error, :identity} = Events.parse(output, %{@identity | run_id: "other"})
  end

  test "terminal event must be last" do
    output = stream([started(1), completed(2, "passed"), started(3)])
    assert {:error, :terminal_not_last} = Events.parse(output, @identity)
  end

  test "oversized output cannot pass" do
    huge = String.duplicate("x", 65_537)
    assert {:error, :output_too_large} = Events.parse(huge, @identity)
  end

  defp stream(events), do: Enum.map_join(events, "\n", &JSON.encode!/1) <> "\n"

  defp started(seq), do: base(seq, "stage.started")
  defp completed(seq, outcome), do: Map.put(base(seq, "run.completed"), "outcome", outcome)

  defp finding(seq, finding),
    do: Map.put(base(seq, "stage.finding"), "finding", finding)

  defp base(seq, event) do
    %{
      "schema_version" => "1",
      "protocol_version" => "consigliere.made.managed.v1",
      "run_id" => "run-a",
      "invocation_id" => "inv-a",
      "mission_id" => "mission-a",
      "gate_id" => "gate-a",
      "base_sha" => "base",
      "input_sha" => "sha-a",
      "policy_hash" => "p1",
      "sequence" => seq,
      "event" => event
    }
  end
end
