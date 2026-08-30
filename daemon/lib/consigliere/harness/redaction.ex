defmodule Consigliere.Harness.Redaction do
  @moduledoc false

  @credential_patterns [
    ~r/\bgithub_pat_[A-Za-z0-9_]+\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]+\b/,
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/,
    ~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/-]+=*/
  ]

  @sensitive_path_pattern ~r{(?i)(?:/Users|/home|/private/tmp|/tmp)/[^\s"']*(?:\.codex|\.ssh|credentials?|auth\.json)[^\s"']*}

  @quoted_sensitive_assignment_pattern ~r/(?i)(["'](?:access_token|refresh_token|id_token|oauth_token|token|password|secret|api[_-]?key|credential|CS_CAPABILITY|OPENAI_API_KEY|ANTHROPIC_API_KEY)["']\s*[:=]\s*)["']?[^\s,"'}]+/
  @bare_sensitive_assignment_pattern ~r/(?i)(\b(?:CS_CAPABILITY|token|password|secret|private[_-]?key|api[_-]?key|credential|OPENAI_API_KEY|ANTHROPIC_API_KEY)\b\s*[:=]\s*)["']?[^\s,"'}]+/
  @compound_sensitive_assignment_pattern ~r/(?i)(\b(?:AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|PRIVATE_KEY|PRIVATE_KEY_PEM|OPENAI_API_KEY|ANTHROPIC_API_KEY)\b\s*=\s*)["']?[^\s,"'}]+/
  @sensitive_key_names ~w(auth authorization capability cs_capability attempt_capability)
  @sensitive_key_fragments ~w(token password secret credential api_key api-key private_key private-key)

  def text(value) when is_binary(value) do
    value
    |> redact_assignments()
    |> redact_pem()
    |> redact_known_tokens()
  end

  def text(value), do: to_string(value)

  def value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, value(nested)}
    end)
  end

  def value(value) when is_list(value), do: Enum.map(value, &value/1)
  def value(value) when is_binary(value), do: text(value)
  def value(value), do: value

  defp redact_assignments(value) do
    value = Regex.replace(@quoted_sensitive_assignment_pattern, value, "\\1[REDACTED]")
    value = Regex.replace(@bare_sensitive_assignment_pattern, value, "\\1[REDACTED]")
    Regex.replace(@compound_sensitive_assignment_pattern, value, "\\1[REDACTED]")
  end

  defp redact_pem(value) do
    {lines, _in_block} =
      value
      |> String.split("\n", trim: false)
      |> Enum.map_reduce(false, fn line, in_block ->
        marker = String.upcase(line)

        begins? =
          String.contains?(marker, "-----BEGIN") and String.contains?(marker, "PRIVATE KEY-----")

        ends? =
          String.contains?(marker, "-----END") and String.contains?(marker, "PRIVATE KEY-----")

        cond do
          begins? and ends? -> {"[REDACTED PEM]", false}
          begins? -> {"[REDACTED PEM]", true}
          in_block and ends? -> {"[REDACTED PEM]", false}
          in_block -> {"[REDACTED PEM]", true}
          true -> {line, false}
        end
      end)

    Enum.join(lines, "\n")
  end

  defp redact_known_tokens(value) do
    value = Regex.replace(@sensitive_path_pattern, value, "[SENSITIVE_PATH]")

    Enum.reduce(@credential_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  defp sensitive_key?(key) when is_binary(key) or is_atom(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in @sensitive_key_names or
      Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(_key), do: false
end
