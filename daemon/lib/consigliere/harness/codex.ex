defmodule Consigliere.Harness.Codex do
  @moduledoc """
  Production Codex adapter. cs-runner owns the OS process group; this
  module owns argv, JSONL translation, and isolated CODEX_HOME. Session
  state is not kept in an Elixir Agent.
  """
  @behaviour Consigliere.Harness.Adapter

  @max_text 4_096

  @impl true
  def capabilities do
    %{
      "supports_native_resume" => false,
      "supports_interrupt" => false,
      "harness_name" => "codex",
      "adapter_contract_version" => 1
    }
  end

  def policy(project) do
    dp = (project && project.dispatch_policy) || %{}

    %{
      "model" => dp["model"] || "gpt-5",
      "effort" => dp["effort"] || dp["reasoning_effort"] || "high",
      "sandbox" => dp["sandbox"] || "workspace-write",
      "approval" => dp["approval"] || dp["ask_for_approval"] || "never"
    }
  end

  def argv(opts) do
    workspace = Keyword.get(opts, :workspace_path, ".")
    prompt = Keyword.fetch!(opts, :prompt)
    policy = Keyword.get(opts, :policy, %{})

    [
      binary!(),
      "exec",
      "--json",
      "--skip-git-repo-check",
      "--model",
      to_string(Map.get(policy, "model", "gpt-5")),
      "--sandbox",
      to_string(Map.get(policy, "sandbox", "workspace-write")),
      "--ask-for-approval",
      to_string(Map.get(policy, "approval", "never")),
      "-c",
      "model_reasoning_effort=#{Map.get(policy, "effort", "high")}",
      "-C",
      workspace,
      prompt
    ]
  end

  def binary! do
    System.get_env("CS_CODEX_BIN") || System.find_executable("codex") ||
      raise("production harness missing: set CS_CODEX_BIN or install codex")
  end

  @impl true
  def start(_spec), do: {:error, :runner_owned}

  @impl true
  def resume(_native_session_id, _spec), do: {:error, :unsupported}

  @impl true
  def send(_ref, _input), do: {:error, :runner_owned}

  @impl true
  def interrupt(_ref), do: {:error, :unsupported}

  @impl true
  def cancel(_ref), do: {:error, :runner_owned}

  @impl true
  def snapshot(ref), do: %{native_session_id: Map.get(ref, :native_session_id)}

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
        {:event, "progress.reported", %{"text" => bound_text(Map.get(map, "text", ""))}}

      "progress.reported" ->
        {:event, "progress.reported", Map.get(map, "payload", %{})}

      "item.completed" ->
        item_event(map["item"] || %{})

      "item.started" ->
        :ignore

      "item.updated" ->
        :ignore

      "checkpoint.created" ->
        {:event, "checkpoint.created",
         %{
           "commit_sha" => map["commit_sha"] || map["sha"],
           "sha" => map["sha"] || map["commit_sha"]
         }}

      "question.requested" ->
        {:event, "question.requested", Map.get(map, "payload", map)}

      "turn.completed" ->
        {:event, "session.completed", %{"usage" => map["usage"] || %{}}}

      "turn.failed" ->
        {:event, "session.failed",
         %{"reason" => failed_reason(map), "class" => "turn_failed"}}

      "thread.completed" ->
        {:event, "session.completed", %{}}

      "session.completed" ->
        {:event, "session.completed", %{}}

      "session.failed" ->
        {:event, "session.failed", %{"reason" => map["reason"] || map["class"] || "failed"}}

      "error" ->
        {:event, "session.failed", %{"reason" => map["message"] || "error", "class" => "fatal"}}

      "usage.updated" ->
        {:event, "usage.updated", Map.get(map, "payload", map)}

      _ ->
        :ignore
    end
  end

  def normalize(_), do: :ignore

  defp item_event(%{"type" => "agent_message"} = item) do
    {:event, "progress.reported", %{"text" => bound_text(item["text"] || "")}}
  end

  defp item_event(%{"type" => "error"} = item) do
    {:event, "progress.reported", %{"text" => bound_text(item["text"] || "item error")}}
  end

  defp item_event(item) when is_map(item) do
    {:event, "artifact.created", item}
  end

  defp item_event(_), do: :ignore

  defp failed_reason(map) do
    case map do
      %{"error" => %{"message" => msg}} when is_binary(msg) -> msg
      %{"message" => msg} when is_binary(msg) -> msg
      _ -> "turn_failed"
    end
  end

  defp bound_text(text) when is_binary(text) do
    if byte_size(text) <= @max_text, do: text, else: binary_part(text, 0, @max_text)
  end

  defp bound_text(_), do: ""
end
