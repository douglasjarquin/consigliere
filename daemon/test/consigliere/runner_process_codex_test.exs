defmodule Consigliere.RunnerProcessCodexTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Harness.Codex
  alias Consigliere.Harness.UsageLedger
  alias Consigliere.Repo
  alias Consigliere.RunnerProcess

  setup do
    Fixtures.reset_phase1_tables!()
    previous = Application.get_env(:consigliere_daemon, :harness_adapter)
    Application.put_env(:consigliere_daemon, :harness_adapter, Codex)

    on_exit(fn ->
      Application.put_env(:consigliere_daemon, :harness_adapter, previous)
    end)

    :ok
  end

  test "runs one fresh Codex JSONL session and records bounded usage" do
    {:ok, mission} =
      Consigliere.Missions.create(
        Fixtures.mission_attrs(%{objective: "run a bounded task"}),
        Actor.boss()
      )

    {:ok, attempt} =
      Consigliere.Repo.insert(
        Attempt.changeset(%Attempt{}, %{
          mission_id: mission.id,
          role: "soldier",
          harness: "codex",
          status: "starting",
          fencing_token: "fence-#{System.unique_integer([:positive])}",
          invocation_id: "invocation-#{System.unique_integer([:positive])}",
          model: "gpt-5",
          reasoning_effort: "high",
          sandbox: "workspace-write",
          approval: "never",
          cli_version: "codex fixture 1.0",
          input_context_hash: String.duplicate("b", 64),
          context_bytes: 256,
          context_input_tokens: 64
        })
      )

    script = Path.join(System.tmp_dir!(), "codex-jsonl-#{System.unique_integer([:positive])}")
    log_path = Path.join(Consigliere.Home.logs_dir(), "attempts/#{attempt.id}.log")

    File.write!(
      script,
      "#!/bin/sh\n" <>
        "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"session-1\"}'\n" <>
        "printf '%s\\n' '{\"type\":\"agent_message\",\"text\":\"Bearer super-secret\"}'\n" <>
        "printf '%s\\n' '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":12,\"cached_input_tokens\":3,\"output_tokens\":7,\"total_tokens\":19}}'\n"
    )

    File.chmod!(script, 0o700)

    on_exit(fn ->
      File.rm(script)
      File.rm(log_path)
      File.rm(UsageLedger.path(Consigliere.Home.dir(), attempt.id))
    end)

    {:ok, runner} =
      RunnerProcess.start_link(
        attempt_id: attempt.id,
        mission_id: mission.id,
        fencing_token: attempt.fencing_token,
        workspace_path: System.tmp_dir!(),
        workspace_generation: "lease-1",
        invocation_id: attempt.invocation_id,
        project_id: mission.project_id,
        context_hash: attempt.input_context_hash,
        policy: %{
          "model" => attempt.model,
          "effort" => attempt.reasoning_effort,
          "cli_version" => attempt.cli_version
        },
        harness_command: [script]
      )

    wait_until(fn ->
      Repo.get!(Attempt, attempt.id).status in ~w(completed failed lost canceled superseded)
    end)

    reloaded = Repo.get!(Attempt, attempt.id)
    assert reloaded.status == "failed"
    assert reloaded.exit_classification == "protocol_failure"
    assert reloaded.native_session_id == "session-1"
    assert reloaded.invocation_id == attempt.invocation_id
    assert reloaded.context_bytes == 256
    assert reloaded.context_input_tokens == 64

    [usage] =
      UsageLedger.path(Consigliere.Home.dir(), attempt.id)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert usage["mission_id"] == mission.id
    assert usage["attempt_id"] == attempt.id
    assert usage["session_id"] == "session-1"
    assert usage["input_tokens"] == 12
    assert usage["cached_input_tokens"] == 3
    assert usage["output_tokens"] == 7
    assert usage["total_tokens"] == 19
    log = File.read!(log_path)
    refute log =~ attempt.input_context_hash
    refute log =~ "super-secret"

    assert not Process.alive?(runner)
  end

  defp wait_until(fun, remaining \\ 100) do
    if fun.() do
      :ok
    else
      if remaining <= 0 do
        flunk("condition did not become true")
      else
        Process.sleep(50)
        wait_until(fun, remaining - 1)
      end
    end
  end
end
