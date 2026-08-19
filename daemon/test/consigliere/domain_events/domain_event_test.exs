defmodule Consigliere.DomainEvents.DomainEventTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.DomainEvents.DomainEvent

  test "a valid changeset inserts, and ids are monotonically increasing for polling" do
    attrs = %{
      type: "mission.created",
      subject_type: "mission",
      subject_id: Ecto.UUID.generate(),
      occurred_at: DateTime.utc_now()
    }

    assert {:ok, first} = Repo.insert(DomainEvent.changeset(%DomainEvent{}, attrs))
    assert {:ok, second} = Repo.insert(DomainEvent.changeset(%DomainEvent{}, attrs))

    assert is_integer(first.id)
    assert second.id > first.id
  end

  test "missing type is rejected" do
    attrs = %{subject_type: "mission", subject_id: Ecto.UUID.generate(), occurred_at: DateTime.utc_now()}
    refute DomainEvent.changeset(%DomainEvent{}, attrs).valid?
  end
end
