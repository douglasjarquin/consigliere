defmodule Consigliere.Actor do
  @moduledoc false

  @enforce_keys [:principal]
  defstruct [:principal, :attempt_id, :fencing_token, :channel, :allowed_ops]

  def system, do: %__MODULE__{principal: "daemon", channel: "internal"}

  def boss, do: %__MODULE__{principal: "boss", channel: "privileged"}

  def attempt(attempt_id, fencing_token, allowed_ops \\ nil) do
    %__MODULE__{
      principal: "attempt",
      attempt_id: attempt_id,
      fencing_token: fencing_token,
      channel: "capability",
      allowed_ops: allowed_ops
    }
  end

  def model_advisory do
    %__MODULE__{principal: "model_advisory", channel: "advisory"}
  end
end
