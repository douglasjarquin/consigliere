defmodule Consigliere.Made.Validate do
  @moduledoc """
  Runs one managed-mode validation against a Gate, then records the
  terminal outcome. The validator process is gone before the write.
  """

  alias Consigliere.Actor
  alias Consigliere.Gates
  alias Consigliere.Made.Fake

  def run(gate, attempt, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Fake)
    decisions = Keyword.get(opts, :decisions, [])
    fingerprint = Keyword.get(opts, :fingerprint, "fp-default")

    result =
      adapter.validate(%{
        run_id: gate.managed_run_id || gate.id,
        input_sha: gate.input_sha,
        base_sha: gate.base_sha,
        policy_hash: gate.policy_hash,
        fingerprint: fingerprint,
        decisions: decisions
      })

    if result.live_pid, do: raise("managed-mode left a live validator pid #{result.live_pid}")

    gate = apply_outcome(gate, attempt, result, fingerprint)
    Map.put(result, :gate, gate)
  end

  defp apply_outcome(gate, attempt, %{outcome: :needs_decision}, fingerprint) do
    {:ok, %{gate: gate}} =
      Gates.needs_decision(gate.id, Actor.system(), %{
        managed_run_id: gate.managed_run_id,
        finding_digest: fingerprint,
        question_attrs: %{
          attempt_id: attempt.id,
          request_id: "made-#{gate.id}",
          blocking_scope: "mission",
          requested_authority: "boss",
          prompt: "Made needs a decision on #{fingerprint}"
        }
      })

    gate
  end

  defp apply_outcome(gate, _attempt, %{outcome: :passed}, _fingerprint) do
    {:ok, gate} =
      Gates.pass(gate.id, Actor.system(), %{
        managed_run_id: gate.managed_run_id,
        input_sha: gate.input_sha,
        base_sha: gate.base_sha
      })

    gate
  end
end
