defmodule Consigliere.Harness.CodexTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Fixtures
  alias Consigliere.Harness.Codex
  alias Consigliere.Harness.ContextPack
  alias Consigliere.Harness.Events
  alias Consigliere.Missions
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    previous = System.get_env("CS_CODEX_BIN")
    System.put_env("CS_CODEX_BIN", "/usr/bin/true")

    on_exit(fn ->
      if previous,
        do: System.put_env("CS_CODEX_BIN", previous),
        else: System.delete_env("CS_CODEX_BIN")
    end)

    :ok
  end

  test "capabilities report no native resume" do
    caps = Codex.capabilities()
    assert caps["supports_native_resume"] == false
    assert caps["harness_name"] == "codex"
  end

  test "argv uses the context pack as the prompt and pins dispatch policy" do
    {:ok, mission} =
      Missions.create(
        Fixtures.mission_attrs(%{
          objective: "add ping",
          scope: "lib",
          acceptance_criteria: "pong"
        }),
        Actor.boss()
      )

    {:ok, pack} = ContextPack.compose(mission, %{workspace_path: "/tmp/ws", role: "soldier"})

    argv =
      Codex.argv(
        workspace_path: "/tmp/ws",
        prompt: pack.encoded,
        policy: %{
          "model" => "gpt-5",
          "effort" => "high",
          "sandbox" => "workspace-write",
          "approval" => "never"
        }
      )

    assert List.last(argv) == pack.encoded
    assert pack.hash == ContextPack.hash(List.last(argv))
    refute Enum.any?(argv, &(&1 == "complete the authorized mission"))
    assert "--model" in argv
    assert "gpt-5" in argv
    assert "--sandbox" in argv
    assert "workspace-write" in argv
    assert "--ask-for-approval" in argv
    assert "never" in argv
  end

  test "decode_line maps a successful exec JSONL stream to session.completed" do
    events = decode_fixture("success.jsonl")
    types = Enum.map(events, &elem(&1, 1))
    assert "session.started" in types
    assert "session.completed" in types
    refute "session.failed" in types

    {:event, "session.completed", payload} =
      Enum.find(events, &match?({:event, "session.completed", _}, &1))

    assert payload["usage"]["output_tokens"] == 20

    assert Enum.any?(events, fn
             {:event, "progress.reported", %{"text" => text}} ->
               String.contains?(text, "changed the module as authorized")

             _ ->
               false
           end)
  end

  test "decode_line maps turn.failed and top-level error to session.failed" do
    failed = decode_fixture("turn_failed.jsonl")
    assert Enum.any?(failed, &match?({:event, "session.failed", _}, &1))

    fatal = decode_fixture("fatal_error.jsonl")
    assert Enum.any?(fatal, &match?({:event, "session.failed", _}, &1))
  end

  test "item-level warnings do not prevent a later successful turn.completed" do
    types = Enum.map(decode_fixture("item_warning_then_success.jsonl"), &elem(&1, 1))
    assert "session.completed" in types
    refute "session.failed" in types
  end

  test "truncated JSONL is ignored, not treated as completion" do
    events = decode_fixture("truncated.jsonl")
    refute Enum.any?(events, &match?({:event, "session.completed", _}, &1))
    refute Enum.any?(events, &match?({:event, "session.failed", _}, &1))
  end

  test "ingested turn.completed plus exit 0 completes the Attempt rather than losing it" do
    attempt = running_attempt!()
    ingest_fixture(attempt, "success.jsonl")
    reloaded = Repo.get!(Attempt, attempt.id)
    assert reloaded.exit_classification == "completed"

    {:ok, done} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 0,
        session_completed: reloaded.exit_classification == "completed"
      })

    assert done.status == "completed"
  end

  test "exit 0 without a terminal event is lost" do
    attempt = running_attempt!()
    ingest_fixture(attempt, "truncated.jsonl")
    reloaded = Repo.get!(Attempt, attempt.id)
    refute reloaded.exit_classification == "completed"

    {:ok, lost} =
      Attempts.classify_exit(attempt.id, %{
        process_group: :dead_verified,
        exit_status: 0,
        session_completed: false
      })

    assert lost.status == "lost"
  end

  test "production config selects Codex not Fake" do
    config = File.read!(Path.expand("../../../config/config.exs", __DIR__))
    assert config =~ "harness_adapter: Consigliere.Harness.Codex"
    refute config =~ "harness_adapter: Consigliere.Harness.Fake"
  end

  test "resume is unsupported on the production adapter" do
    assert {:error, :unsupported} = Codex.resume("thr-1", %{attempt_id: "a"})
    assert {:error, :runner_owned} = Codex.start(%{attempt_id: "a", fencing_token: "f"})
  end

  defp decode_fixture(name) do
    Path.expand("../../fixtures/codex/#{name}", __DIR__)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Codex.decode_line(line) do
        {:event, _, _} = event -> [event]
        _ -> []
      end
    end)
  end

  defp ingest_fixture(attempt, name) do
    actor = Actor.attempt(attempt.id, attempt.fencing_token)

    decode_fixture(name)
    |> Enum.with_index(1)
    |> Enum.each(fn {{:event, type, payload}, seq} ->
      {:ok, _} =
        Events.ingest(
          %{
            "event_id" => "#{name}-#{seq}",
            "type" => type,
            "native_sequence" => seq,
            "attempt_id" => attempt.id,
            "payload" => payload
          },
          actor
        )
    end)
  end

  defp running_attempt! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    attempt
  end
end
