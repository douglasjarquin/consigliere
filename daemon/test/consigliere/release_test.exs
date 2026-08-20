defmodule Consigliere.ReleaseTest do
  use ExUnit.Case, async: false

  test "migrate does not stop a running daemon application" do
    assert app_started?()
    assert :ok = Consigliere.Release.migrate()
    assert app_started?()
  end

  defp app_started? do
    match?(
      {:consigliere_daemon, _, _},
      List.keyfind(Application.started_applications(), :consigliere_daemon, 0)
    )
  end
end
