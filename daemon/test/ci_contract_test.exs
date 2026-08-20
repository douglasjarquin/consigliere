defmodule CIContractTest do
  use ExUnit.Case, async: true

  # daemon/test -> repo root. Path.expand from daemon is ../.github/workflows/ci.yml.
  @workflow_path Path.expand("../.github/workflows/ci.yml", Path.expand("..", __DIR__))

  # Paths the deleted Bash lane detector never knew. Fail closed: they must
  # still select daemon mix test and runner go test / go test -race.
  @unknown_paths [
    "unknown/brand-new.xyz",
    "not-a-lane/foo",
    "tmp/scratch",
    "vendor/new-layout/x"
  ]

  setup_all do
    yaml = File.read!(@workflow_path)
    jobs = parse_jobs(yaml)
    {:ok, yaml: yaml, jobs: jobs}
  end

  test "the workflow file exists at the repository root" do
    assert File.exists?(@workflow_path), "missing #{@workflow_path}"
  end

  test "triggers on pull_request and on push to main and rewrite-in-elixer", %{yaml: yaml} do
    on_block = section(yaml, "on")
    assert on_block =~ "pull_request"
    assert on_block =~ "main"
    assert on_block =~ "rewrite-in-elixer"
    refute on_block =~ ~r/^\s+paths:/m
  end

  test "does not depend on deleted legacy Bash CI paths", %{yaml: yaml} do
    refute yaml =~ "bin/cs-lint.sh"
    refute yaml =~ "bin/cs-ci-lanes.sh"
    refute yaml =~ "bin/cs-test-run.sh"
    refute yaml =~ "tests/*.test.sh"
    refute yaml =~ "bin/cs-install-shellcheck.sh"
    refute yaml =~ "bin/cs-herdr"
  end

  test "daemon mix test is present and always on", %{jobs: jobs} do
    job = job_with_command(jobs, "mix test")
    assert job, "CI must run mix test from daemon/"
    assert always_on?(job), "daemon mix test must not be skippable"
    assert working_directory(job) == "daemon"
  end

  test "go test is present and always on", %{jobs: jobs} do
    job = job_with_command(jobs, "go test")
    assert job, "CI must run go test from runner/cs-runner/"
    assert always_on?(job), "go test must not be skippable"
    assert working_directory(job) == "runner/cs-runner"
  end

  test "go test -race is present and always on", %{jobs: jobs} do
    job = job_with_command(jobs, "go test -race")
    assert job, "CI must run go test -race from runner/cs-runner/"
    assert always_on?(job), "go test -race must not be skippable"
    assert working_directory(job) == "runner/cs-runner"
  end

  test "release smoke migrates, boots, pings, doctors, and restarts", %{yaml: yaml, jobs: jobs} do
    job = Map.get(jobs, "smoke")
    assert job, "CI must run a release smoke job"
    assert always_on?(job), "release smoke must not be skippable"
    assert yaml =~ "mix release"
    assert yaml =~ "Consigliere.Release.migrate"
    assert yaml =~ "cs ping"
    assert yaml =~ "cs doctor"
    # Mix release start execs the BEAM. Foreground daemon/start aborts the
    # step on a boot ERROR before sockets can be observed. Smoke must
    # background start and wait on sockets instead of rpc stop
    # (RELEASE_DISTRIBUTION=none).
    assert yaml =~ "beam.pid"
    assert yaml =~ ~r/"\$REL" start/
    refute yaml =~ ~r/"\$REL" daemon\b/
    refute yaml =~ ~r/"\$REL" stop/
  end

  test "an unknown changed path still selects daemon and runner jobs", %{jobs: jobs} do
    for path <- @unknown_paths do
      selected = jobs_for_changed_paths(jobs, [path])

      assert job_with_command(selected, "mix test"),
             "unknown path #{path} skipped daemon mix test"

      assert job_with_command(selected, "go test"),
             "unknown path #{path} skipped go test"

      assert job_with_command(selected, "go test -race"),
             "unknown path #{path} skipped go test -race"
    end
  end

  test "daemon and runner jobs are not gated on a lane detector", %{jobs: jobs} do
    for command <- ["mix test", "go test", "go test -race"] do
      job = job_with_command(jobs, command)
      assert job, "missing job for #{command}"
      refute lane_gated?(job), "#{command} is still gated on a changes/lanes job"
    end
  end

  defp always_on?(job) do
    is_nil(job.if) and not lane_gated?(job)
  end

  defp lane_gated?(job) do
    needs = job.needs || ""
    String.contains?(needs, "changes") or String.contains?(needs, "lanes")
  end

  defp jobs_for_changed_paths(jobs, _paths) do
    # Fail-closed always-on: an unknown path cannot skip jobs that have no
    # job-level `if:` and no lane-detector `needs:`.
    Map.new(for {name, job} <- jobs, always_on?(job), do: {name, job})
  end

  defp job_with_command(jobs, fragment) do
    Enum.find_value(jobs, fn {_name, job} -> command?(job, fragment) && job end)
  end

  defp command?(job, fragment) do
    Enum.any?(job.run, &String.contains?(&1, fragment))
  end

  defp working_directory(job), do: job.working_directory

  defp section(yaml, name) do
    case Regex.run(~r/^#{name}:\n([\s\S]*?)(?=\n[a-zA-Z]|\z)/m, yaml) do
      [_, body] -> body
      nil -> ""
    end
  end

  defp parse_jobs(yaml) do
    case Regex.run(~r/\njobs:\n([\s\S]*)/, yaml) do
      [_, body] ->
        body
        |> String.split(~r/\n(?=  [A-Za-z0-9_-]+:)/)
        |> Enum.map(&parse_one_job/1)
        |> Map.new()

      nil ->
        %{}
    end
  end

  defp parse_one_job(block) do
    [first | rest] = String.split(block, "\n")
    name = first |> String.trim() |> String.trim_trailing(":")
    body = Enum.join(rest, "\n")

    {name,
     %{
       name: name,
       if: job_field(body, "if"),
       needs: job_field(body, "needs"),
       working_directory: yaml_value(body, "working-directory"),
       run: collect_run_commands(body)
     }}
  end

  defp job_field(body, field) do
    case Regex.run(~r/^    #{field}:\s*(.+)$/m, body) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp yaml_value(body, key) do
    case Regex.run(~r/#{Regex.escape(key)}:\s*(.+)/, body) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp collect_run_commands(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], :idle}, fn line, {acc, state} ->
      trimmed = String.trim(line)

      cond do
        match = Regex.run(~r/^\s+-\s+run:\s*(.*)$/, line) ->
          [_, rest] = match
          rest = String.trim(rest)

          cond do
            rest in ["", "|", ">"] -> {acc, :block}
            true -> {[rest | acc], :idle}
          end

        state == :block and String.match?(line, ~r/^\s{8,}\S/) ->
          {[trimmed | acc], :block}

        true ->
          {acc, :idle}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
