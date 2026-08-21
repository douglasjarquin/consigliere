defmodule Consigliere.Made.Events do
  @moduledoc """
  Strict managed-validation JSONL. A Gate cannot pass on exit code alone.
  """

  @schema_version "1"
  @protocol_version "consigliere.made.managed.v1"
  @max_bytes 65_536
  @max_lines 256
  @required ~w(schema_version protocol_version run_id invocation_id mission_id
               gate_id base_sha input_sha policy_hash sequence event)

  def protocol_version, do: @protocol_version
  def schema_version, do: @schema_version

  def parse(output, _identity) when not is_binary(output) or byte_size(output) > @max_bytes do
    {:error, :output_too_large}
  end

  def parse(output, identity) do
    lines = String.split(output, "\n", trim: true)

    cond do
      length(lines) > @max_lines ->
        {:error, :output_too_large}

      true ->
        decode_all(lines, identity)
    end
  end

  defp decode_all(lines, identity) do
    events =
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case JSON.decode(line) do
          {:ok, event} when is_map(event) -> {:cont, {:ok, [event | acc]}}
          _ -> {:halt, {:error, :malformed}}
        end
      end)

    with {:ok, reversed} <- events do
      check_stream(Enum.reverse(reversed), identity)
    end
  end

  defp check_stream([], _identity), do: {:error, :missing_terminal}

  defp check_stream(events, identity) do
    terminals = Enum.filter(events, &(&1["event"] == "run.completed"))
    last = List.last(events)

    cond do
      terminals == [] ->
        {:error, :missing_terminal}

      length(terminals) != 1 or last["event"] != "run.completed" ->
        {:error, :terminal_not_last}

      true ->
        check_identity_and_seq(events, identity, last)
    end
  end

  defp check_identity_and_seq(events, identity, terminal) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {event, seq}, :ok ->
      cond do
        missing_required?(event) -> {:halt, {:error, :malformed}}
        event["sequence"] != seq -> {:halt, {:error, :sequence}}
        not identity_match?(event, identity) -> {:halt, {:error, :identity}}
        true -> {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        {:ok, %{events: events, terminal: terminal, findings: findings(events)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp missing_required?(event), do: Enum.any?(@required, &(not Map.has_key?(event, &1)))

  defp identity_match?(event, identity) do
    event["schema_version"] == @schema_version and
      event["protocol_version"] == @protocol_version and
      event["run_id"] == identity.run_id and
      event["invocation_id"] == identity.invocation_id and
      event["mission_id"] == identity.mission_id and
      event["gate_id"] == identity.gate_id and
      event["base_sha"] == identity.base_sha and
      event["input_sha"] == identity.input_sha and
      event["policy_hash"] == identity.policy_hash
  end

  defp findings(events) do
    Enum.flat_map(events, fn
      %{"event" => "stage.finding", "finding" => finding} when is_map(finding) -> [finding]
      %{"event" => "run.needs_decision", "findings" => list} when is_list(list) -> list
      _ -> []
    end)
  end
end
