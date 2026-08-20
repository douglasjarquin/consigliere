defmodule Consigliere.Harness.Codex do
  @moduledoc """
  Production Codex adapter. cs-runner owns the OS process group; this
  module owns protocol translation and native session metadata.
  """
  @behaviour Consigliere.Harness.Adapter

  @impl true
  def capabilities do
    %{
      "supports_native_resume" => true,
      "supports_interrupt" => true,
      "harness_name" => "codex",
      "adapter_contract_version" => 1
    }
  end

  def argv(opts) do
    bin = binary!()
    workspace = Keyword.get(opts, :workspace_path, ".")
    prompt = Keyword.get(opts, :prompt, default_prompt(opts))

    [
      bin,
      "exec",
      "--json",
      "--skip-git-repo-check",
      "-C",
      workspace,
      prompt
    ]
  end

  def binary! do
    System.get_env("CS_CODEX_BIN") || System.find_executable("codex") ||
      raise("production harness missing: set CS_CODEX_BIN or install codex")
  end

  def decode_line(line) when is_binary(line) do
    case JSON.decode(String.trim(line)) do
      {:ok, map} when is_map(map) -> normalize(map)
      _ -> :ignore
    end
  end

  def normalize(%{"type" => type} = map) do
    case type do
      "thread.started" ->
        {:event, "session.started",
         %{"native_session_id" => map["thread_id"] || map["session_id"] || ""}}

      "session.started" ->
        {:event, "session.started",
         %{"native_session_id" => map["native_session_id"] || map["session_id"] || ""}}

      "turn.started" ->
        {:event, "turn.started", %{}}

      "agent_message" ->
        {:event, "progress.reported", %{"text" => Map.get(map, "text", "")}}

      "progress.reported" ->
        {:event, "progress.reported", Map.get(map, "payload", %{})}

      "item.completed" ->
        {:event, "artifact.created", Map.get(map, "item") || %{}}

      "checkpoint.created" ->
        {:event, "checkpoint.created",
         %{
           "commit_sha" => map["commit_sha"] || map["sha"],
           "sha" => map["sha"] || map["commit_sha"]
         }}

      "question.requested" ->
        {:event, "question.requested", Map.get(map, "payload", map)}

      "turn.completed" ->
        {:event, "turn.completed", %{}}

      "thread.completed" ->
        {:event, "session.completed", %{}}

      "session.completed" ->
        {:event, "session.completed", %{}}

      "session.failed" ->
        {:event, "session.failed", %{"reason" => map["reason"] || map["class"] || "failed"}}

      "error" ->
        {:event, "session.failed", %{"reason" => map["message"] || "error"}}

      "usage.updated" ->
        {:event, "usage.updated", Map.get(map, "payload", map)}

      _ ->
        :ignore
    end
  end

  def normalize(_), do: :ignore

  @impl true
  def start(spec) do
    ensure_started!()
    session_id = "codex-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    pack = Map.get(spec, :context_pack, "")
    hash = :crypto.hash(:sha256, to_string(pack)) |> Base.encode16(case: :lower)

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
      nil -> {:error, :unknown_session}
      _ -> {:ok, %{native_session_id: native_session_id, attempt_id: spec.attempt_id}}
    end
  end

  @impl true
  def send(_ref, _input), do: :ok

  @impl true
  def interrupt(_ref), do: :ok

  @impl true
  def cancel(_ref), do: :ok

  @impl true
  def snapshot(ref), do: %{native_session_id: ref.native_session_id}

  def start_count do
    ensure_started!()
    Agent.get(__MODULE__, & &1.starts)
  end

  def reset! do
    ensure_started!()
    Agent.update(__MODULE__, fn _ -> %{sessions: %{}, starts: 0} end)
  end

  defp ensure_started! do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = Agent.start_link(fn -> %{sessions: %{}, starts: 0} end, name: __MODULE__)
        :ok

      _ ->
        :ok
    end
  end

  defp default_prompt(opts) do
    Keyword.get(opts, :objective, "complete the authorized mission")
  end

  defp emit(spec, type, seq, payload) do
    Consigliere.Harness.Events.ingest(
      %{
        "event_id" => "#{type}-#{spec.attempt_id}-#{seq}",
        "type" => type,
        "native_sequence" => seq,
        "attempt_id" => spec.attempt_id,
        "payload" => payload
      },
      Consigliere.Actor.attempt(spec.attempt_id, spec.fencing_token)
    )
  end
end
