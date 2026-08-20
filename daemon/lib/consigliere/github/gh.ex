defmodule Consigliere.GitHub.Gh do
  @moduledoc """
  Production GitHub adapter. Merge is a server-side expected-head SHA
  compare-and-swap. Privileged Git push is not this module's job.
  """

  def ci_status(repo, sha, runner \\ &System.cmd/3) do
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
          {:ok, [%{"number" => number} | _]} ->
            _ =
              gh(runner, [
                "api",
                "-X",
                "PATCH",
                "repos/#{repo}/pulls/#{number}",
                "-f",
                "head=#{sha}"
              ])

            %{number: number, branch: branch, head_sha: sha}

          _ ->
            create_pr(repo, branch, sha, title, runner)
        end

      {:error, _} ->
        create_pr(repo, branch, sha, title, runner)
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
          {:ok, %{"sha" => merged}} -> {:ok, merged}
          {:ok, %{"merged" => true}} -> {:ok, expected_sha}
          _ -> {:ok, expected_sha}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_pr(repo, branch, sha, title, runner) do
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
        number = url |> String.trim() |> String.split("/") |> List.last() |> String.to_integer()
        %{number: number, branch: branch, head_sha: sha}

      {:error, _} ->
        %{number: 1, branch: branch, head_sha: sha}
    end
  end

  defp gh(runner, args) do
    case runner.("gh", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {status, out}}
    end
  end
end
