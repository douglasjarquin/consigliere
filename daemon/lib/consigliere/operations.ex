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
    "mission.get_own" => %{version: @version, mode: :database, required: ~w(mission_id)},
    "mission.request_changes" => %{
      version: @version,
      mode: :database,
      required: ~w(mission_id reason)
    },
    "mission.grant_work" => %{version: @version, mode: :database, required: ~w(mission_id)},
    "mission.continue" => %{
      version: @version,
      mode: :external,
      required: ~w(mission_id checkpoint_sha)
    },
    "mission.cancel" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.pause" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.resume" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "mission.grant_integration" => %{version: @version, mode: :external, required: ~w(mission_id)},
    "question.open" => %{version: @version, mode: :database},
    "question.answer" => %{version: @version, mode: :database, required: ~w(question_id answer)},
    "away.mark" => %{version: @version, mode: :database},
    "away.return" => %{version: @version, mode: :database},
    "attempt.progress" => %{version: @version, mode: :database, required: ~w(attempt_id)},
    "attempt.checkpoint" => %{
      version: @version,
      mode: :database,
      required: ~w(attempt_id mission_id workspace_id workspace_generation base_sha
                   fencing_generation result_sha result_kind terminal_sequence)
    },
    "attempt.complete" => %{
      version: @version,
      mode: :database,
      required: ~w(attempt_id mission_id workspace_id workspace_generation base_sha
                   fencing_generation result_sha result_kind terminal_sequence)
    },
    "attempt.fail" => %{version: @version, mode: :database, required: ~w(attempt_id)},
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
        with :ok <- validate_value(payload),
             :ok <- require_map(payload),
             :ok <- require_fields(payload, required),
             :ok <- validate_result_fields(op, payload) do
          :ok
        end

      _ ->
        validate_value(payload)
    end
  end

  def validate(_op, _payload), do: {:error, "payload must be an object"}

  defp require_map(payload) when is_map(payload), do: :ok
  defp require_map(_payload), do: {:error, "payload must be an object"}

  defp require_fields(payload, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case {field, Map.get(payload, field)} do
        {"terminal_sequence", value} when is_integer(value) and value > 0 ->
          {:cont, :ok}

        {_field, value} when is_binary(value) and byte_size(value) > 0 ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, "#{field} required"}}
      end
    end)
  end

  defp validate_result_fields(op, payload)
       when op in ["attempt.checkpoint", "attempt.complete"] do
    sequence = Map.get(payload, "terminal_sequence")
    kind = Map.get(payload, "result_kind")

    cond do
      not is_integer(sequence) or sequence < 1 -> {:error, "terminal_sequence must be positive"}
      kind not in ["checkpoint", "completed"] -> {:error, "result_kind is invalid"}
      op == "attempt.checkpoint" and kind != "checkpoint" -> {:error, "result_kind mismatch"}
      op == "attempt.complete" and kind != "completed" -> {:error, "result_kind mismatch"}
      true -> :ok
    end
  end

  defp validate_result_fields(_op, _payload), do: :ok

  defp validate_value(value) do
    case Consigliere.V0.Limits.validate_value(value) do
      :ok ->
        :ok

      {:error, :json_depth_exceeded} ->
        {:error, "payload too deep"}

      {:error, :collection_too_large} ->
        {:error, "payload collection is too large"}

      {:error, :string_too_large} ->
        {:error, "payload string is too long"}

      {:error, :invalid_utf8} ->
        {:error, "payload must be UTF-8"}

      {:error, :unsafe_control_sequence} ->
        {:error, "payload contains an unsafe control sequence"}

      {:error, _reason} ->
        {:error, "payload contains an unsupported value"}
    end
  end
end
