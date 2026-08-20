defmodule Consigliere.AttemptStates do
  @moduledoc """
  Single Attempt status contract for scheduler, coordinator, reconciler,
  and termination. Occupying is a slot/cache set; process-may-exist is
  the fail-closed inventory set. planned is occupying and recoverable,
  never proof that an OS process exists.
  """

  @terminal ~w(completed failed lost canceled superseded)
  @occupying ~w(planned starting running checkpoint_requested terminating)
  @recoverable ~w(planned starting)
  @process_may_exist ~w(starting running checkpoint_requested terminating checkpointed)
  @termination_requested ~w(terminating)

  def terminal, do: @terminal
  def occupying, do: @occupying
  def recoverable, do: @recoverable
  def process_may_exist, do: @process_may_exist
  def termination_requested, do: @termination_requested

  def terminal?(status), do: status in @terminal
  def occupying?(status), do: status in @occupying
  def recoverable?(status), do: status in @recoverable
  def process_may_exist?(status), do: status in @process_may_exist
  def termination_requested?(status), do: status in @termination_requested
end
