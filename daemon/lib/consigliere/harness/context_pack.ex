defmodule Consigliere.Harness.ContextPack do
  @moduledoc """
  Bounded Soldier context pack. The hash is persisted on the Attempt;
  the pack itself is not a transcript replay.
  """

  @max_bytes Consigliere.V0.Limits.string_bytes()
  @max_input_tokens 8_192

  @instructions [
    "Follow only the bounded Mission contract in this context pack.",
    "Work only in the exact workspace identity and trusted base named here.",
    "Use only the listed Attempt operations; do not grant work or integration.",
    "Report progress, checkpoints, completion, or failure through the Attempt protocol.",
    "A checkpoint or completion is valid only when the daemon verifies its exact Git SHA.",
    "After the final commit, make the private Attempt reporter the last action and do not run commands after it."
  ]

  def compose(mission, extras \\ %{}) do
    pack = %{
      "objective" => safe_text(mission.objective),
      "scope" => safe_text(mission.scope),
      "acceptance_criteria" => safe_text(mission.acceptance_criteria),
      "project_id" => mission.project_id,
      "mission_id" => mission.id,
      "checkpoint_sha" => mission.current_checkpoint_sha,
      "base_sha" => Map.get(extras, :base_sha) || Map.get(extras, "base_sha") || mission.base_sha,
      "attempt_id" => value(extras, :attempt_id),
      "workspace_id" => value(extras, :workspace_id),
      "workspace_path" => Map.get(extras, :workspace_path) || Map.get(extras, "workspace_path"),
      "workspace_generation" => value(extras, :workspace_generation),
      "fencing_generation" => value(extras, :fencing_generation),
      "invocation_id" => value(extras, :invocation_id),
      "role" => Map.get(extras, :role) || Map.get(extras, "role") || "soldier",
      "checkpoint" => %{
        "sha" => mission.current_checkpoint_sha,
        "summary" => checkpoint_summary(mission.current_checkpoint_sha)
      },
      "instructions" => @instructions,
      "authority" => %{
        "may_grant_work" => false,
        "may_grant_integration" => false,
        "may_answer_boss_questions" => false
      },
      "capability" => %{
        "operations" => Consigliere.Capabilities.worker_operations(),
        "binding" => [
          "capability_id",
          "capability_generation",
          "attempt_id",
          "mission_id",
          "workspace_generation",
          "fencing_generation"
        ],
        "rule" =>
          "The daemon authenticates every request against this Attempt, Mission, workspace, and fence. Caller-declared identity is not authority."
      },
      "protocol" => %{
        "reporter" => "$CS_ATTEMPT_BIN",
        "questions" => "question.open via the matching Attempt capability",
        "progress" => "attempt.progress is bounded and belongs only to this Attempt",
        "checkpoint" =>
          "For a recoverable checkpoint, run $CS_ATTEMPT_BIN checkpoint --sha \"$(git rev-parse HEAD)\"; never infer SHA from prose",
        "completion" =>
          "After the final exact-SHA commit, run $CS_ATTEMPT_BIN complete --sha \"$(git rev-parse HEAD)\" as the last action; terminal_sequence latest is resolved by the daemon, which verifies the native terminal event and runner death before terminal state",
        "failure" =>
          "attempt.fail reports failure; the daemon verifies runner death before terminal state"
      },
      "completion" => %{
        "require_checkpoint" => true,
        "require_terminal_event" => true
      }
    }

    execution =
      extras
      |> stringify()
      |> Map.take(["model", "effort", "sandbox", "approval", "cli_version"])
      |> Map.new(fn {key, value} -> {key, safe_text(value)} end)
      |> stringify_keys()

    pack = pack |> Map.put("execution", execution) |> stringify_keys()
    encoded = encode_sorted(pack)
    bytes = byte_size(encoded)
    input_tokens = div(bytes + 3, 4)

    if bytes > @max_bytes or input_tokens > @max_input_tokens do
      {:error, :too_large}
    else
      {:ok,
       %{
         pack: pack,
         encoded: encoded,
         hash: hash(encoded),
         bytes: bytes,
         input_tokens: input_tokens
       }}
    end
  end

  def hash(encoded) when is_binary(encoded) do
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp checkpoint_summary(sha) when is_binary(sha) and sha != "" do
    "The latest durable checkpoint is #{sha}."
  end

  defp checkpoint_summary(_), do: "No durable checkpoint has been recorded."

  defp safe_text(value), do: Consigliere.Harness.Redaction.text(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp encode_sorted(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, encode_sorted(v)] end)
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, body, ?}])
  end

  defp encode_sorted(list) when is_list(list) do
    body = list |> Enum.map(&encode_sorted/1) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, body, ?]])
  end

  defp encode_sorted(other), do: JSON.encode!(other)
end
