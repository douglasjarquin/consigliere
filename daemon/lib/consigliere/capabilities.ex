defmodule Consigliere.Capabilities do
  @moduledoc """
  Server-issued, generation-bound Attempt capability secrets.

  Only the hash is stored and the raw secret is delivered to the isolated
  Attempt process. The durable record binds that secret to one Attempt,
  Mission, Workspace lease, and fencing generation.
  """

  import Ecto.Query

  alias Consigliere.Attempts.Attempt
  alias Consigliere.Actor
  alias Consigliere.Capabilities.AttemptCapability
  alias Consigliere.DatabaseWriter
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

  @worker_operations ~w(
    ping
    mission.get_own
    attempt.progress
    question.open
    attempt.checkpoint
    attempt.complete
    attempt.fail
  )
  @live_attempt_statuses ~w(starting running checkpoint_requested)
  @max_scope_fields ~w(
    capability_id
    capability_generation
    attempt_id
    mission_id
    workspace_id
    workspace_generation
    fencing_generation
  )

  def worker_operations, do: @worker_operations

  def mint(attempt, opts \\ []) do
    with {:ok, ops} <- validate_operations(Keyword.get(opts, :ops, @worker_operations)),
         {:ok, ttl} <- validate_ttl(Keyword.get(opts, :ttl_seconds, 86_400)) do
      secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      case DatabaseWriter.transaction(fn -> mint_txn(attempt, secret, ttl, ops) end) do
        {:ok, _capability} -> {:ok, secret}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def authenticate(secret) when is_binary(secret) and secret != "" do
    hash = hash(secret)

    case Repo.get_by(AttemptCapability, secret_hash: hash) do
      nil ->
        {:error, "unknown capability"}

      %AttemptCapability{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, "revoked capability"}

      %AttemptCapability{expires_at: expires} = capability ->
        cond do
          not is_struct(expires, DateTime) ->
            {:error, "malformed capability"}

          DateTime.compare(Txn.now(), expires) in [:gt, :eq] ->
            {:error, "expired capability"}

          not valid_record?(capability) ->
            {:error, "malformed capability"}

          true ->
            {:ok, capability}
        end
    end
  end

  def authenticate(_), do: {:error, "missing capability"}

  @doc "Checks a capability and request scope before any operation writer runs."
  def authorize(capability, nil, request) when is_map(request) do
    with :ok <- valid_for_request?(capability),
         {:ok, attempt, mission, workspace} <- current_binding(capability),
         {:ok, declared} <- declared_scope(request),
         :ok <- validate_request_scope(capability, nil, declared),
         :ok <- validate_current_scope(capability, attempt, mission, workspace) do
      :ok
    end
  end

  def authorize(capability, operation, request) when is_binary(operation) and is_map(request) do
    with :ok <- valid_for_request?(capability),
         :ok <- operation_allowed(capability, operation),
         {:ok, attempt, mission, workspace} <- current_binding(capability),
         {:ok, declared} <- declared_scope(request),
         :ok <- validate_request_scope(capability, operation, declared),
         :ok <- validate_current_scope(capability, attempt, mission, workspace) do
      :ok
    end
  end

  def authorize(_capability, _operation, _request), do: {:error, "capability scope mismatch"}

  def actor_metadata(%AttemptCapability{} = capability) do
    %{
      capability_id: capability.id,
      capability_generation: capability.generation,
      mission_id: capability.mission_id,
      workspace_id: capability.workspace_id,
      workspace_generation: capability.workspace_generation,
      expires_at: capability.expires_at
    }
  end

  def revalidate_actor(%Actor{principal: "attempt", capability_id: nil}, _attempt), do: :ok

  def revalidate_actor(
        %Actor{
          principal: "attempt",
          attempt_id: attempt_id,
          fencing_token: fencing_token,
          capability_id: capability_id,
          capability_generation: generation
        },
        attempt
      )
      when is_binary(capability_id) and is_integer(generation) do
    with %AttemptCapability{} = capability <- Repo.get(AttemptCapability, capability_id),
         true <- capability.attempt_id == attempt_id,
         true <- capability.fencing_token == fencing_token,
         true <- capability.generation == generation,
         :ok <- valid_for_request?(capability),
         {:ok, current_attempt, mission, workspace} <- current_binding(capability),
         true <- current_attempt.id == attempt.id,
         :ok <- validate_current_scope(capability, current_attempt, mission, workspace) do
      :ok
    else
      _ -> {:error, :capability}
    end
  end

  def revalidate_actor(_actor, _attempt), do: {:error, :capability}

  def revoke_for_attempt(attempt_id) do
    DatabaseWriter.transaction(fn -> revoke_for_attempt_txn(attempt_id) end)
  end

  def revoke_for_attempt_txn(attempt_id) do
    now = Txn.now()

    {count, _} =
      from(c in AttemptCapability,
        where: c.attempt_id == ^attempt_id and is_nil(c.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    if count > 0 do
      Txn.append_event!("capability.revoked", "attempt", attempt_id, %{"count" => count})
    end

    :ok
  end

  def allowed?(capability, operation) do
    valid_record?(capability) and
      operation in @worker_operations and
      operation in get_in(capability.ops, ["allow"])
  end

  def valid_record?(%AttemptCapability{} = capability) do
    with true <- nonempty_binary?(capability.id),
         true <- nonempty_binary?(capability.attempt_id),
         true <- nonempty_binary?(capability.mission_id),
         true <- is_integer(capability.generation) and capability.generation > 0,
         true <- nonempty_binary?(capability.workspace_id),
         true <- nonempty_binary?(capability.workspace_generation),
         true <- nonempty_binary?(capability.fencing_token),
         true <- is_struct(capability.issued_at, DateTime),
         true <- is_struct(capability.expires_at, DateTime),
         true <- valid_operations?(capability.ops) do
      true
    else
      _ -> false
    end
  end

  def valid_record?(_), do: false

  def hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp mint_txn(attempt, secret, ttl, ops) do
    current = Repo.get(Attempt, attempt.id) || Repo.rollback({:invalid, "attempt_not_found"})

    unless current.mission_id == attempt.mission_id and
             current.workspace_id == attempt.workspace_id and
             current.fencing_token == attempt.fencing_token do
      Repo.rollback({:invalid, "attempt_identity_mismatch"})
    end

    unless current.status in @live_attempt_statuses do
      Repo.rollback({:unauthorized, "attempt_not_live"})
    end

    mission =
      Repo.get(Mission, current.mission_id) || Repo.rollback({:invalid, "mission_not_found"})

    unless mission.phase == "active" do
      Repo.rollback({:unauthorized, "mission_not_active"})
    end

    workspace =
      Repo.get(Workspace, current.workspace_id) ||
        Repo.rollback({:invalid, "workspace_required"})

    unless workspace.mission_id == current.mission_id and workspace.status == "active" do
      Repo.rollback({:unauthorized, "workspace_not_active"})
    end

    now = Txn.now()

    {revoked_count, _} =
      from(c in AttemptCapability,
        where: c.attempt_id == ^current.id and is_nil(c.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    if revoked_count > 0 do
      Txn.append_event!("capability.revoked", "attempt", current.id, %{
        "count" => revoked_count,
        "reason" => "new_generation"
      })
    end

    latest_generation =
      Repo.one(
        from(c in AttemptCapability,
          where: c.attempt_id == ^current.id,
          select: max(c.generation)
        )
      ) || 0

    generation = latest_generation + 1

    capability =
      Txn.insert!(
        AttemptCapability.changeset(%AttemptCapability{}, %{
          secret_hash: hash(secret),
          attempt_id: current.id,
          mission_id: current.mission_id,
          generation: generation,
          workspace_id: workspace.id,
          workspace_generation: workspace.lease_id,
          fencing_token: current.fencing_token,
          issued_at: now,
          expires_at: DateTime.add(now, ttl, :second),
          ops: %{"allow" => ops}
        })
      )

    Txn.append_event!("capability.issued", "attempt", current.id, %{
      "capability_id" => capability.id,
      "mission_id" => current.mission_id,
      "workspace_id" => workspace.id,
      "generation" => generation,
      "operations" => ops
    })

    capability
  end

  defp valid_for_request?(capability) do
    cond do
      not valid_record?(capability) ->
        {:error, "malformed capability"}

      not is_nil(capability.revoked_at) ->
        {:error, "revoked capability"}

      DateTime.compare(Txn.now(), capability.expires_at) in [:gt, :eq] ->
        {:error, "expired capability"}

      true ->
        :ok
    end
  end

  defp operation_allowed(capability, operation) do
    cond do
      operation not in @worker_operations -> {:error, "capability operation not supported"}
      not allowed?(capability, operation) -> {:error, "capability operation not allowed"}
      true -> :ok
    end
  end

  defp current_binding(capability) do
    with %Attempt{} = attempt <- Repo.get(Attempt, capability.attempt_id),
         %Mission{} = mission <- Repo.get(Mission, capability.mission_id),
         %Workspace{} = workspace <- Repo.get(Workspace, capability.workspace_id) do
      {:ok, attempt, mission, workspace}
    else
      _ -> {:error, "capability scope unavailable"}
    end
  end

  defp validate_current_scope(capability, attempt, mission, workspace) do
    latest_generation =
      Repo.one(
        from(c in AttemptCapability,
          where: c.attempt_id == ^capability.attempt_id,
          select: max(c.generation)
        )
      )

    cond do
      attempt.mission_id != capability.mission_id ->
        {:error, "capability scope mismatch"}

      mission.id != capability.mission_id ->
        {:error, "capability scope mismatch"}

      attempt.status not in @live_attempt_statuses ->
        {:error, "capability attempt unavailable"}

      mission.phase != "active" ->
        {:error, "capability mission unavailable"}

      workspace.mission_id != capability.mission_id ->
        {:error, "capability scope mismatch"}

      workspace.status != "active" ->
        {:error, "capability workspace unavailable"}

      workspace.lease_id != capability.workspace_generation ->
        {:error, "capability workspace generation stale"}

      attempt.fencing_token != capability.fencing_token ->
        {:error, "capability fencing generation stale"}

      latest_generation != capability.generation ->
        {:error, "capability generation stale"}

      true ->
        :ok
    end
  end

  defp declared_scope(request) do
    payload = request["payload"] || %{}
    actor = request["actor"] || %{}
    scope = request["scope"] || %{}

    if is_map(payload) and is_map(actor) and is_map(scope) do
      sources = [scope, request, actor, payload]

      Enum.reduce_while(@max_scope_fields, {:ok, %{}}, fn field, {:ok, acc} ->
        values = declared_values(sources, field)

        case Enum.uniq(values) do
          [] -> {:cont, {:ok, acc}}
          [value] -> {:cont, {:ok, Map.put(acc, field, value)}}
          _ -> {:halt, {:error, "capability scope mismatch"}}
        end
      end)
    else
      {:error, "capability scope mismatch"}
    end
  end

  defp declared_values(sources, "fencing_generation") do
    Enum.flat_map(sources, fn source ->
      Enum.flat_map(["fencing_generation", "fencing_token"], fn field ->
        case Map.fetch(source, field) do
          {:ok, value} when not is_nil(value) -> [value]
          _ -> []
        end
      end)
    end)
  end

  defp declared_values(sources, field) do
    Enum.flat_map(sources, fn source ->
      case Map.fetch(source, field) do
        {:ok, value} when not is_nil(value) -> [value]
        _ -> []
      end
    end)
  end

  defp validate_request_scope(capability, operation, declared) do
    required =
      cond do
        operation == "ping" -> []
        is_nil(operation) -> []
        operation == "mission.get_own" -> ["attempt_id", "mission_id"]
        true -> ["attempt_id"]
      end

    if Enum.any?(required, &(not Map.has_key?(declared, &1))) do
      {:error, "capability scope required"}
    else
      expected = %{
        "capability_id" => capability.id,
        "capability_generation" => capability.generation,
        "attempt_id" => capability.attempt_id,
        "mission_id" => capability.mission_id,
        "workspace_id" => capability.workspace_id,
        "workspace_generation" => capability.workspace_generation,
        "fencing_generation" => capability.fencing_token
      }

      Enum.reduce_while(declared, :ok, fn {field, value}, :ok ->
        if Map.get(expected, field) == value do
          {:cont, :ok}
        else
          {:halt, {:error, "capability scope mismatch"}}
        end
      end)
    end
  end

  defp validate_operations(ops) when is_list(ops) do
    if Enum.all?(ops, &is_binary/1) and length(Enum.uniq(ops)) == length(ops) and
         Enum.all?(ops, &(&1 in @worker_operations)) do
      {:ok, ops}
    else
      {:error, {:invalid, "capability_operation_not_supported"}}
    end
  end

  defp validate_operations(_), do: {:error, {:invalid, "capability_operation_not_supported"}}

  defp validate_ttl(ttl) when is_integer(ttl), do: {:ok, ttl}
  defp validate_ttl(_), do: {:error, {:invalid, "capability_ttl_invalid"}}

  defp valid_operations?(%{"allow" => ops}) when is_list(ops),
    do: Enum.all?(ops, &(&1 in @worker_operations)) and length(Enum.uniq(ops)) == length(ops)

  defp valid_operations?(_), do: false

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
