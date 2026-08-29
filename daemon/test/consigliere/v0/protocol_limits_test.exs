defmodule Consigliere.V0.ProtocolLimitsTest do
  use ExUnit.Case, async: false

  alias Consigliere.API.Protocol
  alias Consigliere.Fixtures

  setup do
    Fixtures.reset_phase1_tables!()
    :ok
  end

  test "rejects oversized and unsafe requests before dispatch" do
    oversized =
      JSON.encode!(%{
        "v" => 1,
        "id" => "large",
        "op" => "ping",
        "actor" => %{"principal" => "boss"},
        "payload" => %{"value" => String.duplicate("x", 1_048_500)}
      })

    assert JSON.decode!(Protocol.handle(oversized))["error"]["code"] == "frame_too_large"

    unsafe =
      JSON.encode!(%{
        "v" => 1,
        "id" => "unsafe",
        "op" => "ping",
        "actor" => %{"principal" => "boss"},
        "payload" => %{"value" => "bad\u001b[2J"}
      })

    assert JSON.decode!(Protocol.handle(unsafe))["error"]["code"] == "unsafe_control_sequence"
  end

  test "labels accepted, duplicate, and rejected outcomes" do
    first = request("first", "ping", %{"idempotency_key" => "same-key"})
    duplicate = request("second", "ping", %{"idempotency_key" => "same-key"})
    rejected = request("rejected", "mission.submit", %{"payload" => %{}})

    assert first["outcome"] == "accepted"
    assert duplicate["outcome"] == "duplicate"
    assert duplicate["stored_envelope"] == Map.delete(first, "id")
    assert rejected["outcome"] == "rejected"
    assert rejected["ok"] == false
  end

  defp request(id, op, extra) do
    Protocol.handle(
      JSON.encode!(
        Map.merge(
          %{
            "v" => 1,
            "id" => id,
            "op" => op,
            "actor" => %{"principal" => "boss"},
            "payload" => %{}
          },
          extra
        )
      )
    )
    |> JSON.decode!()
  end
end
