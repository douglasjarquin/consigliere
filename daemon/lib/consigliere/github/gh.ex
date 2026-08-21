defmodule Consigliere.GitHub.Gh do
  @moduledoc """
  Production GitHub adapter. Merge is a server-side expected-head SHA
  compare-and-swap. Privileged Git push is not this module's job.
  """

  def ci_status(repo, sha, runner \\ &System.cmd/3) do
    combine_status(combined_status(repo, sha, runner), check_runs(repo, sha, runner))
  end

  def upsert_pr(repo, branch, sha, runner \\ &System.cmd/3) do
    title = "consigliere #{branch}"

    case gh(runner, [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--json",
           "number,headRefOid"
         ]) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, [%{"number" => number, "headRefOid" => head} | _]} when is_integer(number) ->
            if head == sha do
              {:ok, %{number: number, branch: branch, head_sha: sha}}
            else
              {:error, {:stale_pr_head, head}}
            end

          {:ok, []} ->
            create_pr(repo, branch, sha, title, runner)

          _ ->
            {:error, :unrecognized_pr_list}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def merge(repo, pr, expected_sha, runner \\ &System.cmd/3) do
    case gh(runner, ["api", "repos/#{repo}/pulls/#{pr}"]) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"head" => %{"sha" => ^expected_sha}}} ->
            merge_at(repo, pr, expected_sha, runner)

          {:ok, %{"head" => %{"sha" => other}}} ->
            {:error, {:head_moved, other}}

          _ ->
            {:error, :unknown_head}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_at(repo, pr, expected_sha, runner) do
    case gh(runner, [
           "api",
           "-X",
           "PUT",
           "repos/#{repo}/pulls/#{pr}/merge",
           "-f",
           "sha=#{expected_sha}",
           "-f",
           "merge_method=squash"
         ]) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"merged" => true, "sha" => merged}} when is_binary(merged) and merged != "" ->
            {:ok, merged}

          {:ok, %{"sha" => merged, "merged" => true}} when is_binary(merged) and merged != "" ->
            {:ok, merged}

          _ ->
            {:error, :unrecognized_merge}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_pr(repo, branch, sha, title, runner \\ &System.cmd/3) do
    case gh(runner, [
           "pr",
           "create",
           "--repo",
           repo,
           "--head",
           branch,
           "--title",
           title,
           "--body",
           "exact-SHA delivery"
         ]) do
      {:ok, url} ->
        case url |> String.trim() |> String.split("/") |> List.last() |> Integer.parse() do
          {number, ""} -> {:ok, %{number: number, branch: branch, head_sha: sha}}
          _ -> {:error, :unrecognized_pr_url}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp combined_status(repo, sha, runner) do
    case gh(runner, ["api", "repos/#{repo}/commits/#{sha}/status"]) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"state" => "success"}} -> :success
          {:ok, %{"state" => "pending"}} -> :pending
          {:ok, %{"state" => "failure"}} -> :failure
          {:ok, %{"state" => "error"}} -> :failure
          _ -> :unknown
        end

      {:error, _} ->
        :unknown
    end
  end

  defp check_runs(repo, sha, runner) do
    case gh(runner, ["api", "repos/#{repo}/commits/#{sha}/check-runs"]) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"check_runs" => runs}} when is_list(runs) ->
            cond do
              Enum.any?(runs, &(&1["conclusion"] in ["failure", "timed_out", "cancelled"])) ->
                :failure

              Enum.any?(runs, &(&1["status"] in ["queued", "in_progress"])) ->
                :pending

              runs != [] and
                  Enum.all?(
                    runs,
                    &(&1["status"] == "completed" and &1["conclusion"] == "success")
                  ) ->
                :success

              true ->
                :unknown
            end

          _ ->
            :unknown
        end

      {:error, _} ->
        :unknown
    end
  end

  defp combine_status(:failure, _), do: :failure
  defp combine_status(_, :failure), do: :failure
  defp combine_status(:pending, _), do: :pending
  defp combine_status(_, :pending), do: :pending
  defp combine_status(:success, :success), do: :success
  defp combine_status(:success, :unknown), do: :unknown
  defp combine_status(:unknown, :success), do: :success
  defp combine_status(_, _), do: :unknown

  defp gh(runner, args) do
    case runner.("gh", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {status, out}}
    end
  end
end
