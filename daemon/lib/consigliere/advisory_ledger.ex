defmodule Consigliere.AdvisoryLedger do
  @moduledoc """
  Private, bounded measurements for model-advisory orientation calls.

  This ledger contains identity, counters, and snapshot size only. It never
  stores prompts, transcripts, credentials, command output, or repository
  contents.
  """

  alias Consigliere.Home
  alias Consigliere.Harness.Redaction
  alias Consigliere.V0.Limits

  @max_rows Limits.usage_rows()
  @max_bytes Limits.usage_bytes()
  @max_snapshot_bytes Limits.semantic_payload_bytes()
  @max_row_bytes 4_096
  @max_field_bytes 256
  @string_keys ~w(system session_id model effort cli_version context_hash project_id mission_id outcome)
  @counter_keys ~w(turn compactions resets human_interventions input_tokens output_tokens cached_input_tokens total_tokens)

  def record(identity, usage, snapshot_bytes, home \\ Home.dir())

  def record(identity, usage, snapshot_bytes, home)
      when is_map(identity) and is_map(usage) and is_integer(snapshot_bytes) do
    with :ok <- validate_snapshot_bytes(snapshot_bytes),
         {:ok, row} <- build_row(identity, usage, snapshot_bytes),
         {:ok, encoded} <- encode_row(row),
         :ok <- append_bounded(Home.advisory_ledger_path(home), encoded) do
      {:ok, :recorded}
    else
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, :ledger_unavailable}
  end

  def record(_identity, _usage, _snapshot_bytes, _home), do: {:error, :malformed}

  defp validate_snapshot_bytes(bytes)
       when bytes >= 0 and bytes <= @max_snapshot_bytes,
       do: :ok

  defp validate_snapshot_bytes(_bytes), do: {:error, :snapshot_too_large}

  defp build_row(identity, usage, snapshot_bytes) do
    row =
      %{
        "v" => 1,
        "recorded_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "snapshot_bytes" => snapshot_bytes
      }
      |> put_strings(identity)
      |> put_counters(identity)
      |> put_usage(usage)

    {:ok, row}
  end

  defp put_strings(row, identity) do
    Enum.reduce(@string_keys, row, fn key, acc ->
      case bounded_string(value(identity, key)) do
        nil -> acc
        text -> Map.put(acc, key, text)
      end
    end)
  end

  defp put_counters(row, identity) do
    Enum.reduce(@counter_keys, row, fn key, acc ->
      case bounded_counter(value(identity, key)) do
        nil -> acc
        number -> Map.put(acc, key, number)
      end
    end)
  end

  defp put_usage(row, usage) do
    Enum.reduce(~w(input_tokens output_tokens cached_input_tokens total_tokens), row, fn key,
                                                                                         acc ->
      case bounded_counter(value(usage, key)) do
        nil -> acc
        number -> Map.put(acc, key, number)
      end
    end)
  end

  defp bounded_string(value) when is_binary(value) and byte_size(value) <= @max_field_bytes do
    value = Redaction.text(value)
    if String.valid?(value) and String.printable?(value), do: value, else: nil
  end

  defp bounded_string(_value), do: nil

  defp bounded_counter(value) when is_integer(value) and value >= 0 and value <= 2_147_483_647,
    do: value

  defp bounded_counter(_value), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp encode_row(row) do
    encoded = JSON.encode!(row) <> "\n"

    if byte_size(encoded) <= @max_row_bytes,
      do: {:ok, encoded},
      else: {:error, :row_too_large}
  rescue
    _ -> {:error, :malformed}
  end

  defp append_bounded(path, encoded) do
    result =
      :global.trans({__MODULE__, path}, fn ->
        current_bytes =
          case File.stat(path) do
            {:ok, stat} -> stat.size
            {:error, :enoent} -> 0
            {:error, _} -> @max_bytes
          end

        current_rows =
          case File.read(path) do
            {:ok, body} -> body |> :binary.matches(<<"\n">>) |> length()
            {:error, :enoent} -> 0
            {:error, _} -> @max_rows
          end

        cond do
          current_bytes + byte_size(encoded) > @max_bytes ->
            {:error, :ledger_full}

          current_rows >= @max_rows ->
            {:error, :ledger_full}

          true ->
            File.mkdir_p!(Path.dirname(path))
            File.chmod!(Path.dirname(path), 0o700)
            File.write!(path, encoded, [:append, :binary])
            File.chmod!(path, 0o600)
            :ok
        end
      end)

    case result do
      {:aborted, _reason} -> {:error, :ledger_unavailable}
      other -> other
    end
  end
end
