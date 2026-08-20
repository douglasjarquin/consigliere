defmodule Consigliere.CommandReceipts do
  @moduledoc """
  Durable idempotency for mutating API ops. Scope is the authenticated
  identity, not the principal label. External work runs outside the
  writer transaction.
  """

  alias Consigliere.Actor
  alias Consigliere.CommandReceipts.CommandReceipt
  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn

  def scope(%Actor{principal: "attempt", attempt_id: id, fencing_token: fence})
      when is_binary(id) and is_binary(fence) do
    "attempt:#{id}:#{fence}"
  end

  def scope(%Actor{principal: principal}) when is_binary(principal), do: principal
  def scope(principal) when is_binary(principal), do: principal

  def hash(payload) do
    payload
    |> canonicalize()
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def remember(actor_or_scope, op, key, payload, fun) when is_function(fun, 0) do
    scope = scope(actor_or_scope)
    phash = hash(payload)

    case claim(scope, op, key, phash) do
      {:replay, envelope} ->
        {:ok, :replay, envelope}

      :conflict ->
        {:error, {:invalid, "idempotency_conflict"}}

      {:ok, receipt_id} ->
        result = fun.()
        envelope = encode_result(result)
        finalize(receipt_id, envelope)
        unwrap_fresh(result)

      other ->
        other
    end
  end

  defp claim(scope, op, key, phash) do
    DatabaseWriter.transaction(fn ->
      case Repo.get_by(CommandReceipt, principal: scope, idempotency_key: key) do
        %CommandReceipt{op: ^op, payload_hash: ^phash, status: "committed", response: response} ->
          {:replay, response}

        %CommandReceipt{op: ^op, payload_hash: ^phash, status: "pending"} ->
          Repo.rollback(:idempotency_conflict)

        %CommandReceipt{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          row =
            Txn.insert!(
              CommandReceipt.changeset(%CommandReceipt{}, %{
                idempotency_key: key,
                op: op,
                principal: scope,
                payload_hash: phash,
                response: %{},
                status: "pending"
              })
            )

          {:ok, row.id}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, :idempotency_conflict} -> :conflict
      other -> other
    end
  end

  defp finalize(receipt_id, envelope) do
    DatabaseWriter.transaction(fn ->
      row = Repo.get!(CommandReceipt, receipt_id)

      Txn.update!(
        CommandReceipt.changeset(row, %{
          response: envelope,
          status: "committed"
        })
      )
    end)
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp encode_result({:ok, %{id: id, phase: phase}}),
    do: %{"ok" => true, "payload" => %{"id" => id, "phase" => phase}}

  defp encode_result({:ok, %{id: id, status: status}}),
    do: %{"ok" => true, "payload" => %{"id" => id, "status" => status}}

  defp encode_result({:ok, map}) when is_map(map),
    do: %{"ok" => true, "payload" => stringify(map)}

  defp encode_result({:error, {:unauthorized, reason}}),
    do: %{"ok" => false, "code" => "unauthorized", "reason" => inspect(reason)}

  defp encode_result({:error, {:illegal_transition, reason}}),
    do: %{"ok" => false, "code" => "illegal_transition", "reason" => inspect(reason)}

  defp encode_result({:error, {:not_found, what}}),
    do: %{"ok" => false, "code" => "not_found", "reason" => to_string(what)}

  defp encode_result({:error, {:invalid, reason}}),
    do: %{"ok" => false, "code" => "invalid", "reason" => to_string(reason)}

  defp encode_result({:error, reason}),
    do: %{"ok" => false, "code" => "error", "reason" => inspect(reason)}

  defp encode_result(other),
    do: %{"ok" => true, "payload" => %{"value" => inspect(other)}}

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp unwrap_fresh(result), do: result
end
