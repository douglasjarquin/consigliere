defmodule Consigliere.Gates.Support do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Gates.Gate
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger
  alias Consigliere.DomainEvents.DomainEvent

  def fetch_gate!(id) do
    case Repo.get(Gate, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      gate -> gate
    end
  end

  def fetch_mission!(id) do
    case Repo.get(Mission, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      mission -> mission
    end
  end

  def require_status!(gate, from, to) do
    if gate.status == from, do: :ok, else: Txn.illegal(gate.status, to, :wrong_status)
  end

  def match_identity!(gate, attrs) do
    input = Map.get(attrs, :input_sha, gate.input_sha)
    base = Map.get(attrs, :base_sha, gate.base_sha)

    if input != gate.input_sha or base != gate.base_sha do
      Txn.sha_mismatch({gate.input_sha, gate.base_sha}, {input, base})
    end
  end

  def match_run_id!(gate, attrs) do
    got = Map.get(attrs, :managed_run_id)

    if got && gate.managed_run_id && got != gate.managed_run_id do
      Txn.run_id_mismatch(gate.managed_run_id, got)
    end
  end

  def load_or_create_ledger!(gate) do
    case Repo.get_by(MissionValidationLedger,
           mission_id: gate.mission_id,
           gate_type: gate.gate_type
         ) do
      nil ->
        Txn.insert!(
          MissionValidationLedger.changeset(%MissionValidationLedger{}, %{
            mission_id: gate.mission_id,
            gate_type: gate.gate_type
          })
        )

      ledger ->
        ledger
    end
  end

  def policy_int(mission, gate_type, key, default) do
    case get_in(mission.validation_policy, [gate_type, key]) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  def bump_fingerprint(counts, fingerprint) when is_binary(fingerprint) do
    next = Map.update(counts, fingerprint, 1, &(&1 + 1))
    {next, Map.fetch!(next, fingerprint)}
  end

  def bump_fingerprint(counts, _fingerprint), do: {counts, 0}

  def last_event(gate) do
    Repo.one(
      from(e in DomainEvent,
        where: e.subject_id == ^gate.id,
        order_by: [desc: e.id],
        limit: 1
      )
    )
  end
end
