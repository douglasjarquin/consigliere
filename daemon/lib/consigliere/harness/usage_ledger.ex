defmodule Consigliere.Harness.UsageLedger do
  @moduledoc """
  Small private per-Attempt usage ledger.

  Only stable identity fields and non-negative token counters are written.
  The ledger is intentionally local and temporary; it is not a transcript or
  a second source of durable Attempt state.
  """

  alias Consigliere.Home

  @max_rows 4_096
  @max_bytes 1_048_576
  @max_row_bytes 4_096
  @max_field_bytes 256
  @counter_keys ~w(input_tokens output_tokens cached_input_tokens total_tokens)
  @identity_keys ~w(system project_id mission_id attempt_id session_id model effort cli_version context_hash)

  def path(home, attempt_id),
    do: Path.join([Home.runtime_attempts_dir(home), attempt_id, "usage.jsonl"])

  def record(identity, usage, home \\ Home.dir())

  def record(identity, usage, home) when is_map(identity) and is_map(usage) do
    with :ok <- validate_attempt_id(identity_value(identity, "attempt_id")),
         row <- build_row(identity, usage),
         {:ok, encoded} <- encode_row(row),
         ledger_path = path(home, identity_value(identity, "attempt_id")),
         :ok <- ensure_capacity(ledger_path, encoded),
         :ok <- append(ledger_path, encoded) do
      {:ok, :recorded}
    else
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, :ledger_unavailable}
  end

  def record(_identity, _usage, _home), do: {:error, :malformed}

  defp build_row(identity, usage) do
    row =
      identity
      |> stringify_identity()
      |> Map.put(
        "recorded_at",
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      )

    Enum.reduce(@counter_keys, row, fn key, acc ->
      case counter(usage, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp stringify_identity(identity) do
    identity
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in @identity_keys do
        case bounded_string(value) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      else
        acc
      end
    end)
  end

  defp counter(usage, key) do
    case Map.get(usage, key) || Map.get(usage, String.to_atom(key)) do
      value when is_integer(value) and value >= 0 and value <= 2_147_483_647 -> value
      _ -> nil
    end
  end

  defp bounded_string(value) when is_binary(value) and byte_size(value) <= @max_field_bytes do
    if String.printable?(value), do: value, else: nil
  end

  defp bounded_string(_), do: nil

  defp encode_row(row) do
    encoded = JSON.encode!(row) <> "\n"

    if byte_size(encoded) <= @max_row_bytes do
      {:ok, encoded}
    else
      {:error, :row_too_large}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp ensure_capacity(path, encoded) do
    current_bytes =
      case File.stat(path) do
        {:ok, stat} -> stat.size
        {:error, :enoent} -> 0
        {:error, _} -> @max_bytes
      end

    if current_bytes + byte_size(encoded) > @max_bytes do
      {:error, :ledger_full}
    else
      current_rows =
        case File.read(path) do
          {:ok, body} -> body |> :binary.matches(<<"\n">>) |> length()
          {:error, :enoent} -> 0
          {:error, _} -> @max_rows
        end

      if current_rows >= @max_rows, do: {:error, :ledger_full}, else: :ok
    end
  end

  defp append(path, encoded) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, encoded, [:append, :binary])
    File.chmod!(path, 0o600)
    :ok
  end

  defp validate_attempt_id(value) do
    if is_binary(value) and value != "" and value == Path.basename(value) and
         value =~ ~r/\A[[:alnum:]_-]+\z/ do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp identity_value(identity, key) do
    Map.get(identity, key) || Map.get(identity, String.to_atom(key))
  end
end
