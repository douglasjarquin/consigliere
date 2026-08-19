defmodule Consigliere.OutboxItems.OutboxItemTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.OutboxItems.OutboxItem

  test "a valid changeset inserts with default status queued and round-trips" do
    attrs = %{kind: "notification", payload: %{"foo" => "bar"}}

    assert {:ok, item} = Repo.insert(OutboxItem.changeset(%OutboxItem{}, attrs))
    reloaded = Repo.get(OutboxItem, item.id)
    assert reloaded.status == "queued"
    assert reloaded.payload == %{"foo" => "bar"}
  end

  test "natural_key and idempotency_key round-trip, and idempotency_key is unique" do
    suffix = System.unique_integer([:positive])

    attrs = %{
      kind: "notification",
      natural_key: "question:q#{suffix}",
      idempotency_key: "question.routed:q#{suffix}"
    }

    assert {:ok, _} = Repo.insert(OutboxItem.changeset(%OutboxItem{}, attrs))

    assert {:error, changeset} = Repo.insert(OutboxItem.changeset(%OutboxItem{}, attrs))
    assert "has already been taken" in errors_for(changeset, :idempotency_key)
  end

  test "an unknown status is rejected" do
    attrs = %{kind: "notification", status: "nonsense"}
    refute OutboxItem.changeset(%OutboxItem{}, attrs).valid?
  end

  defp errors_for(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Map.get(field, [])
  end
end
