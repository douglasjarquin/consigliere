defmodule Consigliere.GitHub.Fake do
  @moduledoc """
  In-process GitHub stand-in for exact-SHA delivery tests.
  CI status is keyed by SHA. Merge is a compare-and-swap on head SHA.
  """

  def start_link do
    Agent.start_link(fn -> %{prs: %{}, heads: %{}, ci: %{}} end)
  end

  def upsert_pr(github, branch, sha) do
    Agent.get_and_update(github, fn state ->
      number = Map.get(state.prs, branch, map_size(state.prs) + 1)
      pr = %{number: number, branch: branch, head_sha: sha}

      {{:ok, pr},
       %{
         state
         | prs: Map.put(state.prs, branch, number),
           heads: Map.put(state.heads, number, sha)
       }}
    end)
  end

  def set_head(github, pr, sha) do
    Agent.update(github, fn state ->
      %{state | heads: Map.put(state.heads, pr, sha)}
    end)
  end

  def set_ci(github, sha, status) do
    Agent.update(github, fn state ->
      %{state | ci: Map.put(state.ci, sha, status)}
    end)
  end

  def ci_status(github, sha) do
    Agent.get(github, fn state -> Map.get(state.ci, sha, :unknown) end)
  end

  def merge(github, pr, expected_sha) do
    Agent.get_and_update(github, fn state ->
      case Map.get(state.heads, pr) do
        ^expected_sha ->
          {{:ok, expected_sha}, %{state | heads: Map.put(state.heads, pr, expected_sha)}}

        other ->
          {{:error, {:head_moved, other}}, state}
      end
    end)
  end
end
