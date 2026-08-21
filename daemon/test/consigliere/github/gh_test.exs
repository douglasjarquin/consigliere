defmodule Consigliere.GitHub.GhTest do
  use ExUnit.Case, async: true

  alias Consigliere.GitHub.Gh

  test "merge is an expected-head SHA compare-and-swap" do
    runner = fn
      "gh", ["api", "repos/acme/app/pulls/7"], _ ->
        {~s({"head":{"sha":"abc123"}}), 0}

      "gh", ["api", "-X", "PUT", "repos/acme/app/pulls/7/merge" | rest], _ ->
        assert Enum.any?(rest, &String.contains?(&1, "sha=abc123"))
        {~s({"sha":"abc123","merged":true}), 0}
    end

    assert {:ok, "abc123"} = Gh.merge("acme/app", 7, "abc123", runner)
  end

  test "merge refuses a moved head" do
    runner = fn
      "gh", ["api", "repos/acme/app/pulls/7"], _ ->
        {~s({"head":{"sha":"moved"}}), 0}
    end

    assert {:error, {:head_moved, "moved"}} = Gh.merge("acme/app", 7, "abc123", runner)
  end

  test "ci_status maps GitHub commit status" do
    runner = fn
      "gh", ["api", "repos/acme/app/commits/abc/status"], _ ->
        {~s({"state":"success"}), 0}

      "gh", ["api", "repos/acme/app/commits/abc/check-runs"], _ ->
        {~s({"check_runs":[{"status":"completed","conclusion":"success"}]}), 0}
    end

    assert :success = Gh.ci_status("acme/app", "abc", runner)
  end

  test "ci_status fails closed when a required check run failed" do
    runner = fn
      "gh", ["api", "repos/acme/app/commits/abc/status"], _ ->
        {~s({"state":"success"}), 0}

      "gh", ["api", "repos/acme/app/commits/abc/check-runs"], _ ->
        {~s({"check_runs":[{"status":"completed","conclusion":"failure"}]}), 0}
    end

    assert :failure = Gh.ci_status("acme/app", "abc", runner)
  end

  test "create_pr failure is an error, never a fabricated PR #1" do
    runner = fn "gh", ["pr", "create" | _], _ ->
      {"authentication required", 1}
    end

    assert {:error, {1, "authentication required"}} =
             Gh.create_pr("acme/app", "head", "sha", "title", runner)
  end

  test "upsert_pr does not invent success when list and create fail" do
    runner = fn "gh", _args, _ -> {"boom", 1} end
    assert {:error, {1, "boom"}} = Gh.upsert_pr("acme/app", "head", "sha", runner)
  end

  test "malformed merge JSON is an error not synthetic success" do
    runner = fn
      "gh", ["api", "repos/acme/app/pulls/7"], _ ->
        {~s({"head":{"sha":"abc123"}}), 0}

      "gh", ["api", "-X", "PUT", "repos/acme/app/pulls/7/merge" | _], _ ->
        {~s({"ok":true}), 0}
    end

    assert {:error, :unrecognized_merge} = Gh.merge("acme/app", 7, "abc123", runner)
  end

  test "production config selects Gh not Fake" do
    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
    assert config =~ "github_adapter: Consigliere.GitHub.Gh"
    refute config =~ "github_adapter: Consigliere.GitHub.Fake"
  end
end
