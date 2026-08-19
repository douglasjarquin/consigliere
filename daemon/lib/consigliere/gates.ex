defmodule Consigliere.Gates do
  @moduledoc false

  alias Consigliere.Gates.Transitions

  defdelegate create(mission_id, actor, attrs), to: Transitions
  defdelegate start(gate_id, actor, attrs), to: Transitions
  defdelegate pass(gate_id, actor, attrs), to: Transitions
  defdelegate needs_decision(gate_id, actor, attrs), to: Transitions
  defdelegate fail_retryable(gate_id, actor, attrs), to: Transitions
  defdelegate fail_terminal(gate_id, actor, attrs), to: Transitions
  defdelegate record_infrastructure_error(gate_id, actor), to: Transitions
  defdelegate retry_infrastructure(gate_id, actor), to: Transitions
  defdelegate rerun_after_decision(gate_id, actor, decision_id), to: Transitions
  defdelegate cancel(gate_id, actor), to: Transitions
  defdelegate invalidate(gate_id, actor), to: Transitions
end
