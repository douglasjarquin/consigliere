defmodule Consigliere.GitHub.FakeTest do
  use ExUnit.Case, async: true

  alias Consigliere.GitHub.Fake

  setup do
    {:ok, github} = Fake.start_link()
    %{github: github}
  end

  test "upsert_pr is idempotent on branch and tracks head SHA", %{github: github} do
    pr = Fake.upsert_pr(github, "refs/heads/delivery", "sha-a")
    again = Fake.upsert_pr(github, "refs/heads/delivery", "sha-b")
    assert again.number == pr.number
    assert again.head_sha == "sha-b"
  end

  test "merge succeeds only when the head SHA matches the expected SHA", %{github: github} do
    pr = Fake.upsert_pr(github, "refs/heads/delivery", "sha-a")
    assert {:ok, "sha-a"} = Fake.merge(github, pr.number, "sha-a")

    Fake.upsert_pr(github, "refs/heads/other", "sha-b")
    pr2 = Fake.upsert_pr(github, "refs/heads/moved", "sha-c")
    Fake.set_head(github, pr2.number, "sha-other")
    assert {:error, {:head_moved, "sha-other"}} = Fake.merge(github, pr2.number, "sha-c")
  end

  test "CI status for SHA A cannot apply to SHA B", %{github: github} do
    Fake.set_ci(github, "sha-a", :success)
    assert Fake.ci_status(github, "sha-a") == :success
    assert Fake.ci_status(github, "sha-b") == :unknown
  end
end
