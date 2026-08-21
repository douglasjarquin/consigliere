defmodule Consigliere.Harness.ContextPack do
  @moduledoc """
  Bounded Soldier context pack. The hash is persisted on the Attempt;
  the pack itself is not a transcript replay.
  """

  @max_bytes 64_000

  def compose(mission, extras \\ %{}) do
    pack = %{
      "objective" => mission.objective,
      "scope" => mission.scope,
      "acceptance_criteria" => mission.acceptance_criteria,
      "project_id" => mission.project_id,
      "mission_id" => mission.id,
      "checkpoint_sha" => mission.current_checkpoint_sha,
      "base_sha" => Map.get(extras, :base_sha) || Map.get(extras, "base_sha") || mission.base_sha,
      "workspace_path" => Map.get(extras, :workspace_path) || Map.get(extras, "workspace_path"),
      "role" => Map.get(extras, :role) || Map.get(extras, "role") || "soldier",
      "authority" => %{
        "may_grant_work" => false,
        "may_grant_integration" => false,
        "may_answer_boss_questions" => false
      },
      "protocol" => %{
        "questions" => "question.open via Attempt capability",
        "checkpoint" => "emit checkpoint.created with the git SHA; never infer SHA from prose"
      },
      "completion" => %{
        "require_checkpoint" => true,
        "require_terminal_event" => true
      }
    }

    pack = pack |> Map.merge(stringify(extras)) |> stringify_keys()
    encoded = encode_sorted(pack)

    if byte_size(encoded) > @max_bytes do
      {:error, :too_large}
    else
      {:ok, %{pack: pack, encoded: encoded, hash: hash(encoded)}}
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
