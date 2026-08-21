defmodule Consigliere.Capabilities do
  @moduledoc """
  Server-issued Attempt capability secrets. Only the hash is stored.
  The raw secret is delivered to the isolated Attempt process only.
  """

  alias Consigliere.Capabilities.AttemptCapability
  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn

  @default_ops ["ping", "mission.get", "question.open"]

  def mint(attempt, opts \\ []) do
    secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    hash = hash(secret)
    ttl = Keyword.get(opts, :ttl_seconds, 86_400)
    ops = Keyword.get(opts, :ops, @default_ops)

    {:ok, _row} =
      DatabaseWriter.transaction(fn ->
        Txn.insert!(
          AttemptCapability.changeset(%AttemptCapability{}, %{
            secret_hash: hash,
            attempt_id: attempt.id,
            mission_id: attempt.mission_id,
            fencing_token: attempt.fencing_token,
            ops: %{"allow" => ops},
            expires_at: DateTime.add(Txn.now(), ttl, :second)
          })
        )
      end)

    {:ok, secret}
  end

  def authenticate(secret) when is_binary(secret) and secret != "" do
    hash = hash(secret)

    case Repo.get_by(AttemptCapability, secret_hash: hash) do
      nil ->
        {:error, "unknown capability"}

      %AttemptCapability{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, "revoked capability"}

      %AttemptCapability{expires_at: expires} = cap ->
        if DateTime.compare(Txn.now(), expires) == :gt do
          {:error, "expired capability"}
        else
          {:ok, cap}
        end
    end
  end

  def authenticate(_), do: {:error, "missing capability"}

  def revoke_for_attempt(attempt_id) do
    DatabaseWriter.transaction(fn ->
      import Ecto.Query

      from(c in AttemptCapability,
        where: c.attempt_id == ^attempt_id and is_nil(c.revoked_at)
      )
      |> Repo.all()
      |> Enum.each(fn cap ->
        Txn.update!(AttemptCapability.changeset(cap, %{revoked_at: Txn.now()}))
      end)

      :ok
    end)
  end

  def allowed?(cap, op) do
    allow = get_in(cap.ops, ["allow"]) || []
    op in allow
  end

  def hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
