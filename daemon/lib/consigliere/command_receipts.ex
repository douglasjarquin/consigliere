defmodule Consigliere.CommandReceipts do
  @moduledoc """
  Durable idempotency for Local V0 operations.

  Database-only transitions run in a short writer transaction after the receipt
  claim, while external work claims a receipt, runs after that transaction has
  released the writer, and records a bounded result later.
  """

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.CommandReceipts.CommandReceipt
  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn

  @result_version 1
  @max_key_bytes 256
  @max_detail_bytes 512

  def scope(%Actor{
        principal: "attempt",
        attempt_id: id,
        fencing_token: fence,
        capability_id: capability_id,
        capability_generation: generation
      })
      when is_binary(id) and id != "" and is_binary(fence) and fence != "" and
             is_binary(capability_id) and capability_id != "" and is_integer(generation) do
    "attempt:#{id}:#{fence}:capability:#{capability_id}:#{generation}"
  end

  def scope(%Actor{principal: "attempt", attempt_id: id, fencing_token: fence})
      when is_binary(id) and id != "" and is_binary(fence) and fence != "" do
    "attempt:#{id}:#{fence}"
  end

  def scope(%Actor{principal: "attempt"}), do: "invalid:attempt_identity_required"
  def scope(%Actor{principal: principal}) when is_binary(principal), do: principal
  def scope(principal) when is_binary(principal), do: principal
  def scope(_), do: "invalid:authority_scope"

  def canonical_request(actor_or_scope, op, key, payload) do
    with {:ok, scope} <- authority_scope(actor_or_scope),
         {:ok, version} <- Consigliere.Operations.version(op),
         :ok <- validate_key(key),
         :ok <- Consigliere.Operations.validate(op, payload),
         {:ok, canonical} <-
           canonical_json(%{
             "authority_scope" => scope,
             "idempotency_key" => key,
             "operation" => %{"name" => op, "version" => version},
             "payload" => payload
           }) do
      {:ok, canonical}
    end
  end

  def request_hash(actor_or_scope, op, key, payload) do
    with {:ok, canonical} <- canonical_request(actor_or_scope, op, key, payload) do
      {:ok, digest(canonical)}
    end
  end

  def hash(payload) do
    payload
    |> canonical_json!()
    |> digest()
  end

  defp digest(canonical), do: :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

  def remember(actor_or_scope, op, key, payload, fun) when is_function(fun, 0) do
    with {:ok, prepared} <- prepare_request(actor_or_scope, op, key, payload) do
      if Consigliere.Operations.database_only?(op) do
        remember_database(prepared, fun)
      else
        remember_external(prepared, fun)
      end
    end
  end

  def result_envelope({:ok, %{id: id, phase: phase}}) do
    success_envelope(%{"id" => id, "phase" => phase})
  end

  def result_envelope({:ok, %{id: id, status: status}}) do
    success_envelope(%{"id" => id, "status" => status})
  end

  def result_envelope({:ok, map}) when is_map(map), do: success_envelope(map)

  def result_envelope({:error, {:idempotency_conflict, _reason}}),
    do: error_envelope("idempotency_conflict", "idempotency_conflict")

  def result_envelope({:error, {:invalid, "idempotency_conflict"}}),
    do: error_envelope("idempotency_conflict", "idempotency_conflict")

  def result_envelope({:error, {:conflict, reason}}),
    do: error_envelope("conflict", bounded_reason(reason))

  def result_envelope({:error, {:unauthorized, reason}}),
    do: error_envelope("unauthorized", bounded_reason(reason))

  def result_envelope({:error, {:illegal_transition, reason}}),
    do: error_envelope("illegal_transition", bounded_reason(reason))

  def result_envelope({:error, {:fenced, attempt_id}}),
    do: error_envelope("fenced", bounded_reason(attempt_id))

  def result_envelope({:error, {:not_found, what}}),
    do: error_envelope("not_found", bounded_reason(what))

  def result_envelope({:error, {:invalid, reason}}),
    do: error_envelope("invalid", bounded_reason(reason))

  def result_envelope({:error, {:transient, reason}}),
    do: transient_envelope("transient", bounded_reason(reason))

  def result_envelope({:error, %Ecto.Changeset{}}),
    do: error_envelope("invalid", "validation_failed")

  def result_envelope({:error, {:operation_recovery_required, operation_id}}) do
    %{
      "v" => @result_version,
      "ok" => false,
      "outcome" => "rejected",
      "error" => %{
        "code" => "operation_recovery_required",
        "reason" => "operation_recovery_required",
        "operation_id" => bounded_reason(operation_id)
      }
    }
  end

  def result_envelope({:error, _reason}),
    do: error_envelope("error", "operation_failed")

  def result_envelope(_other),
    do: error_envelope("error", "operation_failed")

  defp result_envelope(result, operation_id) do
    result
    |> result_envelope()
    |> Map.put("operation_id", operation_id)
  end

  def reconcile_pending do
    DatabaseWriter.transaction(fn ->
      pending =
        Repo.all(
          from(r in CommandReceipt,
            where: r.status == "pending",
            order_by: [asc: r.inserted_at]
          )
        )

      Enum.each(pending, fn row ->
        Txn.update!(
          CommandReceipt.changeset(row, %{
            response: result_envelope({:error, {:operation_recovery_required, row.id}}),
            status: "recovery_required"
          })
        )
      end)

      length(pending)
    end)
  end

  defp remember_database(prepared, fun) do
    case DatabaseWriter.transaction(fn ->
           case claim_txn(prepared) do
             {:replay, envelope} ->
               {:replay, envelope}

             :conflict ->
               :conflict

             {:ok, receipt_id} ->
               result =
                 case Repo.transaction(fn -> invoke(prepared, fun) end) do
                   {:ok, result} -> result
                   {:error, reason} -> {:error, reason}
                 end

               finalize_txn(receipt_id, result_envelope(result))
               {:committed, result}
           end
         end) do
      {:ok, {:replay, envelope}} ->
        {:ok, :replay, envelope}

      {:ok, :conflict} ->
        conflict()

      {:ok, {:committed, result}} ->
        result

      {:error, _reason} ->
        {:error, {:transient, "receipt_finalize_failed"}}
    end
  end

  defp remember_external(prepared, fun) do
    case claim(prepared) do
      {:replay, envelope} ->
        {:ok, :replay, envelope}

      :conflict ->
        conflict()

      {:ok, receipt_id} ->
        result = invoke(prepared, fun)

        case finalize(receipt_id, result_envelope(result, receipt_id)) do
          {:ok, _} -> result
          {:error, _} -> {:error, {:transient, "receipt_finalize_failed"}}
        end

      other ->
        other
    end
  end

  defp conflict, do: {:error, {:invalid, "idempotency_conflict"}}

  defp prepare_request(actor_or_scope, op, key, payload) do
    with {:ok, scope} <- authority_scope(actor_or_scope),
         {:ok, version} <- Consigliere.Operations.version(op),
         :ok <- validate_key(key) do
      case Consigliere.Operations.validate(op, payload) do
        :ok ->
          build_prepared(scope, op, version, key, payload, nil)

        {:error, reason} ->
          build_prepared(scope, op, version, key, payload, reason)
      end
    end
  end

  defp build_prepared(scope, op, version, key, payload, validation) do
    with {:ok, canonical} <-
           canonical_json(%{
             "authority_scope" => scope,
             "idempotency_key" => key,
             "operation" => %{"name" => op, "version" => version},
             "payload" => payload
           }) do
      {:ok,
       %{
         scope: scope,
         op: op,
         key: key,
         request_hash: digest(canonical),
         validation: validation
       }}
    end
  end

  defp claim(prepared) do
    case DatabaseWriter.transaction(fn -> claim_txn(prepared) end) do
      {:ok, result} -> result
      other -> other
    end
  end

  defp claim_txn(%{scope: scope, op: op, key: key, request_hash: request_hash}) do
    case Repo.get_by(CommandReceipt, principal: scope, idempotency_key: key) do
      %CommandReceipt{
        op: ^op,
        payload_hash: ^request_hash,
        status: status,
        response: response
      }
      when status in ["committed", "recovery_required"] ->
        {:replay, response}

      %CommandReceipt{status: "pending"} ->
        :conflict

      %CommandReceipt{} ->
        :conflict

      nil ->
        row =
          Txn.insert!(
            CommandReceipt.changeset(%CommandReceipt{}, %{
              idempotency_key: key,
              op: op,
              principal: scope,
              payload_hash: request_hash,
              response: %{},
              status: "pending"
            })
          )

        {:ok, row.id}
    end
  end

  defp invoke(%{validation: reason}, _fun) when is_binary(reason),
    do: {:error, {:invalid, reason}}

  defp invoke(_prepared, fun) do
    try do
      fun.()
    rescue
      _exception -> {:error, {:invalid, "operation_failed"}}
    catch
      :throw, {DBConnection, _connection_ref, reason} -> Repo.rollback(reason)
      _kind, _reason -> {:error, {:invalid, "operation_failed"}}
    end
  end

  defp finalize(receipt_id, envelope) do
    DatabaseWriter.transaction(fn -> finalize_txn(receipt_id, envelope) end)
  end

  defp finalize_txn(receipt_id, envelope) do
    row = Repo.get!(CommandReceipt, receipt_id)

    Txn.update!(
      CommandReceipt.changeset(row, %{
        response: envelope,
        status: "committed"
      })
    )
  end

  defp authority_scope(%Actor{
         principal: "attempt",
         attempt_id: id,
         fencing_token: fence,
         capability_id: capability_id,
         capability_generation: generation
       })
       when is_binary(id) and id != "" and is_binary(fence) and fence != "" and
              is_binary(capability_id) and capability_id != "" and is_integer(generation) do
    {:ok, "attempt:#{id}:#{fence}:capability:#{capability_id}:#{generation}"}
  end

  defp authority_scope(%Actor{principal: "attempt", attempt_id: id, fencing_token: fence})
       when is_binary(id) and id != "" and is_binary(fence) and fence != "" do
    {:ok, "attempt:#{id}:#{fence}"}
  end

  defp authority_scope(%Actor{principal: "attempt"}),
    do: {:error, {:invalid, "attempt_identity_required"}}

  defp authority_scope(%Actor{principal: principal})
       when is_binary(principal) and principal != "",
       do: {:ok, principal}

  defp authority_scope(scope) when is_binary(scope) and scope != "", do: {:ok, scope}
  defp authority_scope(_), do: {:error, {:invalid, "authority_scope_required"}}

  defp validate_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) in 1..@max_key_bytes do
      :ok
    else
      {:error, {:invalid, "idempotency_key_invalid"}}
    end
  end

  defp validate_key(_key), do: {:error, {:invalid, "idempotency_key_invalid"}}

  defp success_envelope(payload) do
    %{
      "v" => @result_version,
      "ok" => true,
      "outcome" => "accepted",
      "payload" => bounded_value(payload, 0)
    }
  end

  defp error_envelope(code, reason) do
    %{
      "v" => @result_version,
      "ok" => false,
      "outcome" => "rejected",
      "error" => %{"code" => code, "reason" => bounded_reason(reason)}
    }
  end

  defp transient_envelope(code, reason) do
    %{
      "v" => @result_version,
      "ok" => false,
      "outcome" => "transient",
      "error" => %{"code" => code, "reason" => bounded_reason(reason)}
    }
  end

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp bounded_reason(reason) when is_binary(reason) do
    reason
    |> String.slice(0, @max_detail_bytes)
    |> String.replace(~r/[[:cntrl:]]/, " ")
  end

  defp bounded_reason(%{reason: reason}), do: bounded_reason(reason)
  defp bounded_reason(%{"reason" => reason}), do: bounded_reason(reason)
  defp bounded_reason(_reason), do: "operation_failed"

  defp bounded_value(_value, depth) when depth > 5, do: "truncated"

  defp bounded_value(value, _depth) when is_binary(value),
    do: String.slice(value, 0, @max_detail_bytes)

  defp bounded_value(value, _depth) when is_boolean(value), do: value
  defp bounded_value(value, _depth) when is_integer(value), do: value
  defp bounded_value(nil, _depth), do: nil

  defp bounded_value(value, depth) when is_list(value) do
    value
    |> Enum.take(32)
    |> Enum.map(&bounded_value(&1, depth + 1))
  end

  defp bounded_value(value, depth) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(32)
    |> Enum.map(fn {key, nested} ->
      if sensitive_key?(key) do
        {key, "redacted"}
      else
        {key, bounded_value(nested, depth + 1)}
      end
    end)
    |> Map.new()
  end

  defp bounded_value(_value, _depth), do: "redacted"

  defp sensitive_key?(key) do
    downcased = String.downcase(key)

    Enum.any?(
      ["secret", "password", "credential", "capability", "fencing_token"],
      &String.contains?(downcased, &1)
    )
  end

  defp canonical_json!(value) do
    case canonical_json(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  defp canonical_json(value) when is_map(value) do
    with {:ok, entries} <-
           Enum.reduce_while(value, {:ok, []}, fn {key, nested}, {:ok, acc} ->
             with {:ok, key} <- canonical_key(key),
                  {:ok, encoded} <- canonical_json(nested) do
               {:cont, {:ok, [{key, encoded} | acc]}}
             else
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      keys = Enum.map(entries, &elem(&1, 0))

      if length(Enum.uniq(keys)) != length(keys) do
        {:error, "duplicate canonical object key"}
      else
        body =
          entries
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(",", fn {key, encoded} -> JSON.encode!(key) <> ":" <> encoded end)

        {:ok, "{" <> body <> "}"}
      end
    end
  end

  defp canonical_json(value) when is_list(value) do
    with {:ok, encoded} <-
           Enum.reduce_while(value, {:ok, []}, fn nested, {:ok, acc} ->
             case canonical_json(nested) do
               {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok, "[" <> (Enum.reverse(encoded) |> Enum.join(",")) <> "]"}
    end
  end

  defp canonical_json(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, JSON.encode!(value)}, else: {:error, "value is not UTF-8"}
  end

  defp canonical_json(value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: {:ok, JSON.encode!(value)}

  defp canonical_json(_value), do: {:error, "value is not canonical JSON"}

  defp canonical_key(key) when is_binary(key), do: {:ok, key}
  defp canonical_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_key(_key), do: {:error, "object key is not a string"}
end
