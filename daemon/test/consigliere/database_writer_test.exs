defmodule Consigliere.DatabaseWriterTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.DatabaseWriter
  alias Consigliere.Missions.Mission

  setup do
    Consigliere.Fixtures.reset_phase1_tables!()
    project = Consigliere.Fixtures.dummy_project!()

    case Process.whereis(__MODULE__.ProjectId) do
      nil -> {:ok, _} = Agent.start_link(fn -> project.id end, name: __MODULE__.ProjectId)
      pid -> Agent.update(pid, fn _ -> project.id end)
    end

    :ok
  end

  defp mission_attrs(objective) do
    %{
      objective: objective,
      scope: "scope",
      acceptance_criteria: "criteria",
      phase: "draft",
      project_id: Agent.get(__MODULE__.ProjectId, & &1)
    }
  end

  describe "scenario 1: concurrent writers, no SQLITE_BUSY" do
    test "25 concurrent writers all commit with zero SQLITE_BUSY errors" do
      assert_all_concurrent_writes_commit(25, "scenario1-25")
    end

    test "200 concurrent writers all commit with zero SQLITE_BUSY errors" do
      assert_all_concurrent_writes_commit(200, "scenario1-200")
    end

    defp assert_all_concurrent_writes_commit(n, prefix) do
      results =
        1..n
        |> Task.async_stream(
          fn i -> DatabaseWriter.insert_mission(mission_attrs("#{prefix}-#{i}")) end,
          max_concurrency: n,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      errors = Enum.filter(results, &match?({:error, _}, &1))
      assert errors == [], "expected zero errors, got: #{inspect(errors)}"
      assert Enum.count(results, &match?({:ok, _}, &1)) == n

      count =
        Mission
        |> where([m], like(m.objective, ^"#{prefix}-%"))
        |> Repo.aggregate(:count)

      assert count == n
    end
  end

  describe "scenario 2: concurrent reads during writes" do
    test "reads complete without being blocked by or blocking the write path" do
      write_task =
        Task.async(fn ->
          Task.async_stream(
            1..25,
            fn i -> DatabaseWriter.insert_mission(mission_attrs("scenario2-#{i}")) end,
            max_concurrency: 25,
            timeout: 15_000
          )
          |> Enum.to_list()
        end)

      read_results =
        Task.async_stream(
          1..50,
          fn _ -> Repo.aggregate(Mission, :count) end,
          max_concurrency: 50,
          timeout: 15_000
        )
        |> Enum.to_list()

      Task.await(write_task, 15_000)

      assert Enum.all?(read_results, &match?({:ok, _count}, &1))
    end
  end

  describe "scenario 3: busy_timeout under contention" do
    test "a write held open under an artificial delay does not crash the writer" do
      slow_write =
        Task.async(fn ->
          DatabaseWriter.transaction(fn ->
            Process.sleep(300)

            Repo.insert!(Mission.changeset(%Mission{}, mission_attrs("scenario3-slow")))
          end)
        end)

      queued_result = DatabaseWriter.insert_mission(mission_attrs("scenario3-queued"))

      assert {:ok, _} = Task.await(slow_write, 5_000)
      assert {:ok, _} = queued_result
      assert Process.alive?(Process.whereis(DatabaseWriter))
    end
  end

  describe "scenario 4: WAL checkpoint" do
    test "PRAGMA wal_checkpoint runs clean after a write burst" do
      Task.async_stream(
        1..25,
        fn i ->
          DatabaseWriter.insert_mission(mission_attrs("scenario4-#{i}"))
        end,
        max_concurrency: 25,
        timeout: 15_000
      )
      |> Enum.to_list()

      assert {:ok, %{rows: [[_busy, _log_frames, _checkpointed]]}} =
               Repo.query("PRAGMA wal_checkpoint(TRUNCATE)")

      count =
        Mission
        |> where([m], like(m.objective, "scenario4-%"))
        |> Repo.aggregate(:count)

      assert count == 25
    end
  end

  describe "scenario 6: poison-row quarantine" do
    test "a row with an unknown phase value (an app-level invariant SQLite cannot enforce) does not crash the writer" do
      {:ok, %{num_rows: 1}} =
        Repo.query(
          "INSERT INTO missions (id, objective, scope, acceptance_criteria, phase, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))",
          [Ecto.UUID.bingenerate(), "poison-row", "scope", "criteria", "not_a_real_phase_value"]
        )

      assert Process.alive?(Process.whereis(DatabaseWriter))

      poisoned = Repo.all(Mission) |> Enum.find(&(&1.objective == "poison-row"))
      assert poisoned.phase == "not_a_real_phase_value"

      assert {:ok, _} = DatabaseWriter.insert_mission(mission_attrs("scenario6-after-poison"))
    end
  end
end
