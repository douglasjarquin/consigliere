defmodule Consigliere.Harness.Fake do
  @moduledoc """
  In-process adapter for the Phase 3 conformance suite. Sessions live in
  an Agent; resume of an unknown id fails so open_session can fall back.
  """
  @behaviour Consigliere.Harness.Adapter

  alias Consigliere.Actor
  alias Consigliere.Harness.Events

  def ensure_started! do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = Agent.start_link(fn -> %{sessions: %{}, starts: 0, interrupted: MapSet.new()} end, name: __MODULE__)
        :ok

      _pid ->
        :ok
    end
  end

  def reset! do
    ensure_started!()
    Agent.update(__MODULE__, fn _ -> %{sessions: %{}, starts: 0, interrupted: MapSet.new()} end)
  end

  def start_count do
    ensure_started!()
    Agent.get(__MODULE__, & &1.starts)
  end

  @impl true
  def capabilities do
    %{
      "supports_native_resume" => true,
      "supports_interrupt" => true,
      "harness_name" => "fake",
      "adapter_contract_version" => 1
    }
  end

  @impl true
  def start(spec) do
    ensure_started!()
    session_id = "fake-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    pack = Map.get(spec, :context_pack, "")
    hash = :crypto.hash(:sha256, pack) |> Base.encode16(case: :lower)

    Agent.update(__MODULE__, fn st ->
      %{st | sessions: Map.put(st.sessions, session_id, spec), starts: st.starts + 1}
    end)

    emit(spec, "session.started", 1, %{
      "native_session_id" => session_id,
      "input_context_hash" => hash
    })

    emit(spec, "turn.started", 2, %{})
    {:ok, %{native_session_id: session_id, attempt_id: spec.attempt_id, seq: 2}}
  end

  @impl true
  def resume(native_session_id, spec) do
    ensure_started!()

    case Agent.get(__MODULE__, &Map.get(&1.sessions, native_session_id)) do
      nil ->
        {:error, :unknown_session}

      _stored ->
        {:ok, %{native_session_id: native_session_id, attempt_id: spec.attempt_id}}
    end
  end

  @impl true
  def send(_ref, _input), do: :ok

  @impl true
  def interrupt(ref) do
    ensure_started!()
    id = ref.native_session_id
    Agent.update(__MODULE__, fn st -> %{st | interrupted: MapSet.put(st.interrupted, id)} end)
    :ok
  end

  @impl true
  def cancel(_ref), do: :ok

  @impl true
  def snapshot(ref), do: %{native_session_id: ref.native_session_id, interrupted: interrupted?(ref)}

  def interrupted?(ref) do
    ensure_started!()
    Agent.get(__MODULE__, &MapSet.member?(&1.interrupted, ref.native_session_id))
  end

  def request_question(spec, prompt) do
    emit(spec, "question.requested", next_seq(spec), %{
      "question" => prompt,
      "request_id" => "q-#{System.unique_integer([:positive])}",
      "blocking_scope" => "attempt",
      "requested_authority" => "boss"
    })
  end

  defp next_seq(spec) do
    attempt = Consigliere.Repo.get!(Consigliere.Attempts.Attempt, spec.attempt_id)
    (attempt.last_native_sequence || 0) + 1
  end

  defp emit(spec, type, seq, payload) do
    Events.ingest(
      %{
        "event_id" => "#{type}-#{spec.attempt_id}-#{seq}",
        "type" => type,
        "native_sequence" => seq,
        "attempt_id" => spec.attempt_id,
        "payload" => payload
      },
      Actor.attempt(spec.attempt_id, spec.fencing_token)
    )
  end
end
