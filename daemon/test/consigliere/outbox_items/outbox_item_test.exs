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

  test "an unknown status is rejected" do
    attrs = %{kind: "notification", status: "nonsense"}
    refute OutboxItem.changeset(%OutboxItem{}, attrs).valid?
  end
end
