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

  test "redacts compound secret assignments, private keys, and PEM blocks" do
    value =
      "AWS_SECRET_ACCESS_KEY=aws-secret\nPRIVATE_KEY=private-secret\n" <>
        """
        -----BEGIN PRIVATE KEY-----
        private-material
        -----END PRIVATE KEY-----
        """

    redacted = Redaction.text(value)

    refute redacted =~ "aws-secret"
    refute redacted =~ "private-secret"
    refute redacted =~ "private-material"
    assert redacted =~ "[REDACTED]"
  end

  test "redacts provider API key assignments" do
    value = "OPENAI_API_KEY=openai-secret\nANTHROPIC_API_KEY=anthropic-secret"
    redacted = Redaction.text(value)

    refute redacted =~ "openai-secret"
    refute redacted =~ "anthropic-secret"
    assert redacted =~ "[REDACTED]"
  end

  test "redacts private key values in structured events" do
    assert Redaction.value(%{"private_key" => "private-secret"}) == %{
             "private_key" => "[REDACTED]"
           }
  end

  test "redacts camel-case sensitive keys" do
    redacted =
      Redaction.value(%{
        "apiKey" => "api-secret",
        "privateKey" => "private-secret"
      })

    refute redacted["apiKey"] == "api-secret"
    refute redacted["privateKey"] == "private-secret"
    assert redacted == %{"apiKey" => "[REDACTED]", "privateKey" => "[REDACTED]"}
  end
end
