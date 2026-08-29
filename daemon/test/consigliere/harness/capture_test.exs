defmodule Consigliere.Harness.CaptureTest do
  use ExUnit.Case, async: false

  alias Consigliere.Harness.Capture
  alias Consigliere.V0.Limits

  test "retains a bounded head and tail with a truncation marker" do
    path = Path.join(System.tmp_dir!(), "capture-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)

    head = String.duplicate("h", Limits.capture_head_bytes())
    tail = String.duplicate("t", Limits.capture_tail_bytes())

    assert :ok = Capture.append(path, head <> "middle" <> tail)
    assert :ok = Capture.append(path, "final")

    body = File.read!(path)
    assert byte_size(body) <= Limits.capture_bytes()
    assert body =~ "[capture truncated]"
    assert String.starts_with?(body, String.duplicate("h", 100))
    assert String.ends_with?(body, "final")
    assert {:ok, body} = Capture.read(path)
    assert body =~ "[capture truncated]"
  end

  test "rejects unsafe controls before capture" do
    path =
      Path.join(System.tmp_dir!(), "capture-unsafe-#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(path) end)

    assert {:error, :unsafe_control_sequence} = Capture.append(path, "bad\u001b[2J")
    refute File.exists?(path)
  end
end
