defmodule Consigliere.CommandReceipts do
  @moduledoc """
  Durable idempotency for mutating API ops. Same principal+key+payload
  returns the original result. Same key with a different payload is a
  conflict. Git/network stay outside this transaction.
  """

  alias Consigliere.CommandReceipts.CommandReceipt
  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn

  def hash(payload) do
    payload
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def remember(principal, op, key, payload, fun) when is_function(fun, 0) do
    phash = hash(payload)

    DatabaseWriter.transaction(fn ->
      case Repo.get_by(CommandReceipt, principal: principal, idempotency_key: key) do
        %CommandReceipt{payload_hash: ^phash, response: response} ->
          {:replay, response}

        %CommandReceipt{} ->
          Repo.rollback(:idempotency_conflict)

        nil ->
          result = fun.()
          encoded = encode_result(result)

          Txn.insert!(
            CommandReceipt.changeset(%CommandReceipt{}, %{
              idempotency_key: key,
              op: op,
              principal: principal,
              payload_hash: phash,
              response: encoded,
              status: "committed"
            })
          )

          {:fresh, result}
      end
    end)
    |> unwrap()
  end

  defp encode_result({:ok, %{id: id, phase: phase}}), do: %{"id" => id, "phase" => phase}
  defp encode_result({:ok, %{id: id, status: status}}), do: %{"id" => id, "status" => status}
  defp encode_result({:ok, map}) when is_map(map), do: stringify(map)
  defp encode_result({:error, reason}), do: %{"error" => inspect(reason)}
  defp encode_result(other), do: %{"value" => inspect(other)}

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp unwrap({:ok, {:replay, response}}), do: {:ok, :replay, response}
  defp unwrap({:ok, {:fresh, result}}), do: result
  defp unwrap({:error, :idempotency_conflict}), do: {:error, {:invalid, "idempotency_conflict"}}
  defp unwrap(other), do: other
end
