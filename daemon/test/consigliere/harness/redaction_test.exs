defmodule Consigliere.Harness.RedactionTest do
  use ExUnit.Case, async: true

  alias Consigliere.Harness.Redaction

  test "redacts quoted structured credentials and capability environment values" do
    value =
      ~s({"access_token":"synthetic-access","refresh_token":"synthetic-refresh","secret":"synthetic-secret"}) <>
        " CS_CAPABILITY=synthetic-capability"

    redacted = Redaction.text(value)

    refute redacted =~ "synthetic-access"
    refute redacted =~ "synthetic-refresh"
    refute redacted =~ "synthetic-secret"
    refute redacted =~ "synthetic-capability"
    assert redacted =~ "[REDACTED]"
  end
end
