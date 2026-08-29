defmodule Consigliere.V0.LimitsTest do
  use ExUnit.Case, async: true

  alias Consigliere.V0.Limits

  test "publishes the V0 boundaries" do
    assert Limits.frame_bytes() == 1_048_576
    assert Limits.json_depth() == 64
    assert Limits.collection_items() == 256
    assert Limits.string_bytes() == 65_536
    assert Limits.requests_per_connection() == 1_024
    assert Limits.idle_timeout_ms() == 300_000
    assert Limits.capture_bytes() == 8_388_608
    assert Limits.capture_head_bytes() == 4_194_304
    assert Limits.capture_tail_bytes() == 4_194_304
    assert Limits.semantic_payload_bytes() == 65_536
    assert Limits.final_text_bytes() == 4_096
    assert Limits.usage_rows() == 4_096
    assert Limits.usage_bytes() == 1_048_576
  end

  test "rejects oversized, deeply nested, broad, unsafe, and invalid frames" do
    assert {:error, :frame_too_large} =
             Limits.validate_json_frame(String.duplicate("x", Limits.frame_bytes() + 1))

    nested =
      String.duplicate("[", Limits.json_depth() + 1) <>
        "0" <> String.duplicate("]", Limits.json_depth() + 1)

    assert {:error, :json_depth_exceeded} = Limits.validate_json_frame(nested)

    broad = "[" <> Enum.map_join(1..257, ",", &to_string/1) <> "]"
    assert {:error, :collection_too_large} = Limits.validate_json_frame(broad)

    long_string = JSON.encode!(String.duplicate("x", Limits.string_bytes() + 1))
    assert {:error, :string_too_large} = Limits.validate_json_frame(long_string)

    assert {:error, :unsafe_control_sequence} = Limits.validate_json_frame(~s("\u001b[31m"))
    assert {:error, :malformed_json} = Limits.validate_json_frame("{")
    assert {:error, :invalid_utf8} = Limits.validate_json_frame(<<255>>)
  end

  test "validates decoded values without truncating them" do
    assert :ok = Limits.validate_value(%{"items" => Enum.to_list(1..256)})
    assert {:error, :collection_too_large} = Limits.validate_value(Enum.to_list(1..257))
    assert {:error, :string_too_large} = Limits.validate_value(String.duplicate("x", 65_537))
    assert {:error, :json_depth_exceeded} = Limits.validate_value(deep_value(65))
  end

  defp deep_value(0), do: "leaf"
  defp deep_value(depth), do: %{"next" => deep_value(depth - 1)}
end
