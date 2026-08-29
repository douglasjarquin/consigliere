defmodule Consigliere.Actor do
  @moduledoc false

  @enforce_keys [:principal]
  defstruct [
    :principal,
    :attempt_id,
    :mission_id,
    :workspace_id,
    :workspace_generation,
    :fencing_token,
    :fencing_generation,
    :capability_id,
    :capability_generation,
    :expires_at,
    :channel,
    :allowed_ops
  ]

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

  def attempt(attempt_id, fencing_token, allowed_ops, metadata) when is_map(metadata) do
    %__MODULE__{
      principal: "attempt",
      attempt_id: attempt_id,
      mission_id: Map.get(metadata, :mission_id) || Map.get(metadata, "mission_id"),
      workspace_id: Map.get(metadata, :workspace_id) || Map.get(metadata, "workspace_id"),
      workspace_generation:
        Map.get(metadata, :workspace_generation) || Map.get(metadata, "workspace_generation"),
      fencing_token: fencing_token,
      fencing_generation: fencing_token,
      capability_id: Map.get(metadata, :capability_id) || Map.get(metadata, "capability_id"),
      capability_generation:
        Map.get(metadata, :capability_generation) || Map.get(metadata, "capability_generation"),
      expires_at: Map.get(metadata, :expires_at) || Map.get(metadata, "expires_at"),
      channel: "capability",
      allowed_ops: allowed_ops
    }
  end

  def model_advisory do
    %__MODULE__{principal: "model_advisory", channel: "advisory"}
  end
end
