defmodule Consigliere.Harness.Codex do
  @moduledoc """
  Production Codex adapter. cs-runner owns the OS process group; this
  module owns argv, JSONL translation, and isolated CODEX_HOME. Session
  state is not kept in an Elixir Agent.
  """
  @behaviour Consigliere.Harness.Adapter

  @max_text Consigliere.V0.Limits.final_text_bytes()
  @max_version_output 1_024
  @version_timeout_ms 2_000

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
      "model" => dp["model"] || "gpt-5.6-luna",
      "effort" => dp["effort"] || dp["reasoning_effort"] || "high",
      "sandbox" => dp["sandbox"] || "workspace-write",
      "approval" => dp["approval"] || dp["ask_for_approval"] || "never"
    }
  end

  def argv(opts) do
    workspace = Keyword.get(opts, :workspace_path, ".")
    prompt = Keyword.fetch!(opts, :prompt)
    policy = Keyword.get(opts, :policy, %{})
    binary = Keyword.get(opts, :codex_binary) || binary!()

    [
      binary,
      "exec",
      "--json",
      "--skip-git-repo-check",
      "--model",
      to_string(Map.get(policy, "model", "gpt-5.6-luna")),
      "--sandbox",
      to_string(Map.get(policy, "sandbox", "workspace-write")),
      "-c",
      "approval_policy=#{Map.get(policy, "approval", "never")}",
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

  def fresh_invocation_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  def version(binary) when is_binary(binary) do
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        args: ["--version"]
      ])

    collect_version(port, "", System.monotonic_time(:millisecond) + @version_timeout_ms)
  rescue
    _ -> {:error, :version_unavailable}
  end

  def version(_binary), do: {:error, :version_unavailable}

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
        {:event, "session.completed", %{"usage" => usage_payload(map["usage"] || %{})}}

      "turn.failed" ->
        reason = failed_reason(map)
        {:event, "session.failed", %{"reason" => reason, "class" => turn_failure_class(reason)}}

      "thread.completed" ->
        :ignore

      "session.completed" ->
        {:event, "session.completed", %{"usage" => usage_payload(map["usage"] || %{})}}

      "session.failed" ->
        reason = map["reason"] || map["class"] || "failed"
        {:event, "session.failed", %{"reason" => reason, "class" => failure_class(reason)}}

      "error" ->
        reason = map["message"] || nested_error_message(map) || "error"
        class = failure_class(map["code"] || reason)
        {:event, "session.failed", %{"reason" => reason, "class" => class}}

      "usage.updated" ->
        {:event, "usage.updated", usage_payload(Map.get(map, "payload", map))}

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

  defp nested_error_message(%{"error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp nested_error_message(_), do: nil

  defp failure_class(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      normalized =~ ~r/auth|credential|unauthori[sz]ed|login/ -> "authentication_error"
      normalized =~ ~r/budget|token limit|usage limit|quota/ -> "budget_error"
      true -> "infrastructure_error"
    end
  end

  defp failure_class(_), do: "infrastructure_error"

  defp turn_failure_class(reason) do
    case failure_class(reason) do
      "authentication_error" -> "authentication_error"
      "budget_error" -> "budget_error"
      _ -> "semantic_failure"
    end
  end

  defp usage_payload(payload) when is_map(payload) do
    source = Map.get(payload, "usage", payload)

    if is_map(source) do
      %{}
      |> put_counter("input_tokens", source)
      |> put_counter("output_tokens", source)
      |> put_counter("cached_input_tokens", source)
      |> put_counter("total_tokens", source)
    else
      %{}
    end
  end

  defp usage_payload(_), do: %{}

  defp put_counter(result, key, source) do
    case Map.get(source, key) do
      value when is_integer(value) and value >= 0 and value <= 2_147_483_647 ->
        Map.put(result, key, value)

      _ ->
        result
    end
  end

  defp collect_version(port, output, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_port(port)
      {:error, :version_timeout}
    else
      receive do
        {^port, {:data, data}} ->
          next = output <> data

          if byte_size(next) > @max_version_output do
            close_port(port)
            {:error, :version_output_too_large}
          else
            collect_version(port, next, deadline)
          end

        {^port, {:exit_status, 0}} ->
          case String.trim(output) do
            "" -> {:error, :version_empty}
            version -> {:ok, version}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:version_exit, status}}
      after
        remaining ->
          close_port(port)
          {:error, :version_timeout}
      end
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp bound_text(text) when is_binary(text) do
    if byte_size(text) <= @max_text, do: text, else: binary_part(text, 0, @max_text)
  end

  defp bound_text(_), do: ""
end
