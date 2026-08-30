defmodule Consigliere.Harness.Redaction do
  @moduledoc false

  @credential_patterns [
    ~r/\bgithub_pat_[A-Za-z0-9_]+\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]+\b/,
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/,
    ~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/-]+=*/
  ]

  @sensitive_path_pattern ~r{(?i)(?:/Users|/home|/private/tmp|/tmp)/[^\s"']*(?:\.codex|\.ssh|credentials?|auth\.json)[^\s"']*}

  @sensitive_assignment_pattern ~r/(?i)(["']?(?:[a-z0-9_-]*(?:token|password|secret|api[_-]?key|credential)[a-z0-9_-]*|CS_CAPABILITY)["']?\s*[:=]\s*)["']?[^\s,"'}]+/

  def text(value) when is_binary(value) do
    value
    |> redact_assignments()
    |> redact_known_tokens()
  end

  def text(value), do: to_string(value)

  def value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, value(nested)} end)
  end

  def value(value) when is_list(value), do: Enum.map(value, &value/1)
  def value(value) when is_binary(value), do: text(value)
  def value(value), do: value

  defp redact_assignments(value) do
    Regex.replace(@sensitive_assignment_pattern, value, "\\1[REDACTED]")
  end

  defp redact_known_tokens(value) do
    value = Regex.replace(@sensitive_path_pattern, value, "[SENSITIVE_PATH]")

    Enum.reduce(@credential_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end
end
