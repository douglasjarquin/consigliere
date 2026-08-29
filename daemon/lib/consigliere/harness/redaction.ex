defmodule Consigliere.Harness.Redaction do
  @moduledoc false

  @credential_patterns [
    ~r/\bgithub_pat_[A-Za-z0-9_]+\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]+\b/,
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/,
    ~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/-]+=*/
  ]

  def text(value) when is_binary(value) do
    value
    |> redact_assignments()
    |> redact_known_tokens()
  end

  def text(value), do: to_string(value)

  defp redact_assignments(value) do
    Regex.replace(
      ~r/(?i)\b(token|password|secret|api[_-]?key|credential)\s*[:=]\s*["']?[^\s,"']+/,
      value,
      "\\1=[REDACTED]"
    )
  end

  defp redact_known_tokens(value) do
    Enum.reduce(@credential_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end
end
