defmodule Consigliere.Operations do
  @moduledoc """
  The single versioned operation registry for the Local V0 protocol.

  The registry is deliberately small. It identifies the operations that may
  receive durable receipts and whether their callbacks are database-only.
  """

  @version 1

  @registry %{
    "ping" => %{version: @version, mode: :database},
    "project.add" => %{version: @version, mode: :external, required: ~w(name repository_path)},
    "mission.create" => %{
      version: @version,
      mode: :database,
      required: ~w(project_id objective scope acceptance_criteria)
    },
    "mission.submit" => %{version: @version, mode: :database, required: ~w(mission_id)},
    "mission.request_changes" => %{
      version: @version,
      mode: :database,
      required: ~w(mission_id reason)
    },
    "mission.grant_work" => %{version: @version, mode: :database, required: ~w(mission_id)},
    "mission.continue" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.cancel" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.pause" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.resume" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.grant_integration" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "question.open" => %{version: @version, mode: :database},
    "question.answer" => %{version: @version, mode: :database, required: ~w(question_id answer)},
    "away.mark" => %{version: @version, mode: :database},
    "away.return" => %{version: @version, mode: :database},
    "attempt.progress" => %{version: @version, mode: :external, required: ~w(attempt_id)},
    "attempt.checkpoint" => %{version: @version, mode: :external, required: ~w(attempt_id)},
    "attempt.completion" => %{version: @version, mode: :external, required: ~w(attempt_id)},
    "attempt.failure" => %{version: @version, mode: :external, required: ~w(attempt_id)},
    "internal.dispatch" => %{version: @version, mode: :external, required: ~w(attempt_id)},
    "post_attempt.progress" => %{version: @version, mode: :external, required: ~w(attempt_id)}
  }

  def version(op) when is_binary(op) do
    case Map.get(@registry, op) do
      %{version: version} -> {:ok, version}
      nil -> {:error, "unknown_operation"}
    end
  end

  def spec(op) when is_binary(op), do: Map.get(@registry, op)

  def mutating?(op), do: Map.has_key?(@registry, op)

  def database_only?(op) do
    case spec(op) do
      %{mode: :database} -> true
      _ -> false
    end
  end

  def validate(op, payload) when is_binary(op) do
    case spec(op) do
      nil ->
        {:error, "unknown_operation"}

      %{required: required} ->
        with :ok <- validate_json_value(payload, 0),
             :ok <- require_map(payload),
             :ok <- require_fields(payload, required) do
          :ok
        end

      _ ->
        validate_json_value(payload, 0)
    end
  end

  def validate(_op, _payload), do: {:error, "payload must be an object"}

  defp require_map(payload) when is_map(payload), do: :ok
  defp require_map(_payload), do: {:error, "payload must be an object"}

  defp require_fields(payload, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case Map.get(payload, field) do
        value when is_binary(value) and byte_size(value) > 0 ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, "#{field} required"}}
      end
    end)
  end

  defp validate_json_value(_value, depth) when depth > 8, do: {:error, "payload too deep"}

  defp validate_json_value(value, depth) when is_map(value) do
    if map_size(value) > 128 do
      {:error, "payload has too many fields"}
    else
      Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
        with :ok <- validate_key(key),
             :ok <- validate_json_value(nested, depth + 1) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_json_value(value, depth) when is_list(value) do
    if length(value) > 128 do
      {:error, "payload list is too long"}
    else
      Enum.reduce_while(value, :ok, fn nested, :ok ->
        case validate_json_value(nested, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_json_value(value, _depth) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, "payload must be UTF-8"}
      byte_size(value) > 8_192 -> {:error, "payload string is too long"}
      true -> :ok
    end
  end

  defp validate_json_value(value, _depth) when is_integer(value), do: :ok
  defp validate_json_value(value, _depth) when is_boolean(value), do: :ok
  defp validate_json_value(nil, _depth), do: :ok
  defp validate_json_value(_value, _depth), do: {:error, "payload contains an unsupported value"}

  defp validate_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) <= 256 do
      :ok
    else
      {:error, "payload key is invalid"}
    end
  end

  defp validate_key(key) when is_atom(key), do: validate_key(Atom.to_string(key))
  defp validate_key(_key), do: {:error, "payload key is invalid"}
end
