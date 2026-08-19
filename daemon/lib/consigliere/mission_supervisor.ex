defmodule Consigliere.MissionSupervisor do
  use Supervisor

  # Wraps exactly one MissionCoordinator so its restart intensity is scoped
  # to this one mission, not shared across every mission under
  # MissionDynamicSupervisor. MissionCoordinator itself stays
  # restart: :permanent, since criterion 2 depends on it being auto-restarted
  # and reattaching, unlike RunnerProcess which is disposable (:temporary).
  #
  # This wrapper is itself restart: :temporary at the MissionDynamicSupervisor
  # level (overriding child_spec/1 below). A mission's coordinator crashing
  # past THIS supervisor's own max_restarts:3/max_seconds:5 means the
  # coordinator is genuinely crash-looping, not transiently failing -- if
  # MissionDynamicSupervisor blindly resurrected a given-up subtree, that
  # subtree's own churn would eventually exhaust MissionDynamicSupervisor's
  # shared budget too, cascading the exact blast radius this module exists to
  # prevent one level up (round-3 verification-gate finding). A subtree that
  # has genuinely given up must never be auto-resurrected under a shared
  # budget, mirroring RunnerProcess's own restart: :temporary reasoning.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :supervisor,
      shutdown: :infinity
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children = [{Consigliere.MissionCoordinator, opts}]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
