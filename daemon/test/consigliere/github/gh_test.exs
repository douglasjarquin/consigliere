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
    runner = fn "gh", ["api", "repos/acme/app/commits/abc/status"], _ ->
      {~s({"state":"success"}), 0}
    end

    assert :success = Gh.ci_status("acme/app", "abc", runner)
  end

  test "production config selects Gh not Fake" do
    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
    assert config =~ "github_adapter: Consigliere.GitHub.Gh"
    refute config =~ "github_adapter: Consigliere.GitHub.Fake"
  end
end
