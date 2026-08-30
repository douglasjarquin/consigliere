defmodule Consigliere.ProjectVerifications do
  @moduledoc """
  Runs the bounded local Project verification list after exact-SHA import.

  Commands are literal argv arrays. The daemon never invokes a shell, passes
  only a scrubbed environment, and stores command/output digests rather than
  raw output.
  """

  import Ecto.Query

  alias Consigliere.AttemptResults.AttemptResult
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DatabaseWriter
  alias Consigliere.Missions.Mission
  alias Consigliere.Projects.Project
  alias Consigliere.ProjectVerifications.Command
  alias Consigliere.ProjectVerifications.VerificationRun
  alias Consigliere.Repo
  alias Consigliere.Txn

  @max_commands 8
  @default_commands [["git", "diff", "--check", "{result_sha}"]]

  def run(
        %Attempt{} = attempt,
        %Mission{} = mission,
        %AttemptResult{} = result,
        gate_type,
        opts \\ []
      ) do
    project = Keyword.get(opts, :project) || Repo.get(Project, mission.project_id)

    with {:ok, commands} <- commands(mission, project, opts),
         {:ok, outcomes} <- run_commands(commands, attempt, mission, result, gate_type, opts) do
      if Enum.all?(outcomes, &(&1.outcome == "passed")),
        do: {:ok, :passed, outcomes},
        else: {:error, outcomes}
    end
  end

  def runs(attempt_id) do
    Repo.all(
      from(r in VerificationRun,
        where: r.attempt_id == ^attempt_id,
        order_by: [asc: r.ordinal]
      )
    )
  end

  defp commands(mission, project, opts) do
    if forced = Keyword.get(opts, :forced_outcome) do
      {:ok, [{:forced, forced}]}
    else
      policy = validation_policy(mission, project, opts)

      configured =
        if is_map(policy),
          do: Map.get(policy, "commands") || Map.get(policy, :commands) || @default_commands,
          else: :invalid_policy

      cond do
        configured == :invalid_policy -> {:error, :verification_policy_invalid}
        not is_list(configured) or configured == [] -> {:error, :verification_commands_invalid}
        length(configured) > @max_commands -> {:error, :verification_commands_too_many}
        Enum.all?(configured, &literal_argv?/1) -> {:ok, configured}
        true -> {:error, :verification_command_invalid}
      end
    end
  end

  defp validation_policy(mission, project, opts) do
    case Keyword.fetch(opts, :validation_policy) do
      {:ok, policy} ->
        policy

      :error ->
        project_policy = if match?(%Project{}, project), do: project.validation_policy, else: %{}

        Map.merge(
          if(is_map(project_policy), do: project_policy, else: %{}),
          mission_policy(mission)
        )
    end
  end

  defp mission_policy(%Mission{validation_policy: policy}) when is_map(policy), do: policy
  defp mission_policy(_mission), do: %{}

  defp run_commands(commands, attempt, mission, result, gate_type, opts) do
    total_timeout = Keyword.get(opts, :total_timeout_ms, 1_800_000)
    started = System.monotonic_time(:millisecond)

    Enum.reduce_while(Enum.with_index(commands, 1), {:ok, []}, fn {command, ordinal},
                                                                  {:ok, done} ->
      case command do
        {:forced, forced} ->
          outcome = forced_outcome(forced)
          run = persist_forced(attempt, mission, result, gate_type, ordinal, outcome)
          {:cont, {:ok, done ++ [run]}}

        argv ->
          remaining = total_timeout - (System.monotonic_time(:millisecond) - started)

          if remaining <= 0 do
            run =
              persist_result(
                attempt,
                gate_type,
                ordinal,
                %{outcome: "infrastructure_error", error_code: "total_timeout", timed_out: true}
              )

            {:halt, {:ok, done ++ [run]}}
          else
            resolved = substitute(argv, result.reported_sha)
            identity = command_identity(resolved)

            run = begin_run(attempt, mission, result, gate_type, ordinal, identity, resolved)

            if run.outcome in VerificationRun.outcomes() and run.outcome != "running" do
              finish_or_continue(run, done)
            else
              command_result =
                Command.run(resolved, attempt_workspace(attempt),
                  timeout_ms: Keyword.get(opts, :command_timeout_ms, 900_000),
                  total_timeout_ms: remaining,
                  cancel: Keyword.get(opts, :cancel, false)
                )

              finished =
                persist_result(attempt, gate_type, ordinal, command_result, run.id)

              if finished.outcome == "passed",
                do: {:cont, {:ok, done ++ [finished]}},
                else: {:halt, {:ok, done ++ [finished]}}
            end
          end
      end
    end)
  end

  defp finish_or_continue(run, done) do
    if run.outcome == "passed",
      do: {:cont, {:ok, done ++ [run]}},
      else: {:halt, {:ok, done ++ [run]}}
  end

  defp begin_run(attempt, mission, result, gate_type, ordinal, identity, argv) do
    DatabaseWriter.transaction(fn ->
      case Repo.get_by(VerificationRun,
             attempt_id: attempt.id,
             gate_type: gate_type,
             ordinal: ordinal
           ) do
        nil ->
          Txn.insert!(
            VerificationRun.changeset(%VerificationRun{}, %{
              attempt_id: attempt.id,
              mission_id: mission.id,
              result_id: result.id,
              gate_type: gate_type,
              ordinal: ordinal,
              command_identity: identity,
              argv: %{"argv" => argv},
              input_sha: result.reported_sha,
              started_at: Txn.now(),
              outcome: "running"
            })
          )

        run ->
          if run.command_identity == identity and run.input_sha == result.reported_sha,
            do: run,
            else: Txn.illegal("verification", "running", :verification_identity_mismatch)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp persist_result(attempt, gate_type, ordinal, command_result, run_id \\ nil) do
    DatabaseWriter.transaction(fn ->
      run =
        (run_id && Repo.get!(VerificationRun, run_id)) ||
          Repo.get_by!(VerificationRun,
            attempt_id: attempt.id,
            gate_type: gate_type,
            ordinal: ordinal
          )

      attrs = %{
        outcome: Map.fetch!(command_result, :outcome),
        finished_at: Txn.now(),
        exit_status: Map.get(command_result, :exit_status),
        timed_out: Map.get(command_result, :timed_out, false),
        output_bytes: Map.get(command_result, :output_bytes, 0),
        output_digest: Map.get(command_result, :output_digest),
        error_code: Map.get(command_result, :error_code)
      }

      Txn.update!(VerificationRun.changeset(run, attrs))
    end)
    |> unwrap_transaction_result()
  end

  defp persist_forced(attempt, mission, result, gate_type, ordinal, forced) do
    DatabaseWriter.transaction(fn ->
      case Repo.get_by(VerificationRun,
             attempt_id: attempt.id,
             gate_type: gate_type,
             ordinal: ordinal
           ) do
        %VerificationRun{} = run ->
          run

        nil ->
          attrs = %{
            attempt_id: attempt.id,
            mission_id: mission.id,
            result_id: result.id,
            gate_type: gate_type,
            ordinal: ordinal,
            command_identity: "forced:#{forced}",
            argv: %{"argv" => ["builtin", "forced", to_string(forced)]},
            input_sha: result.reported_sha,
            started_at: Txn.now(),
            finished_at: Txn.now(),
            outcome: forced,
            output_bytes: 0,
            output_digest: digest(to_string(forced))
          }

          Txn.insert!(VerificationRun.changeset(%VerificationRun{}, attrs))
      end
    end)
    |> unwrap_transaction_result()
  end

  defp forced_outcome(:passed), do: "passed"
  defp forced_outcome(:failed), do: "failed"
  defp forced_outcome(:failed_retryable), do: "failed"
  defp forced_outcome(:failed_terminal), do: "failed"
  defp forced_outcome(:needs_decision), do: "canceled"
  defp forced_outcome(:infrastructure_error), do: "infrastructure_error"
  defp forced_outcome(:canceled), do: "canceled"
  defp forced_outcome(_), do: "infrastructure_error"

  defp literal_argv?(argv) when is_list(argv) and argv != [] do
    Enum.all?(argv, fn arg ->
      is_binary(arg) and byte_size(arg) > 0 and
        byte_size(arg) <= Consigliere.V0.Limits.string_bytes() and
        Consigliere.V0.Limits.validate_text(arg) == :ok
    end)
  end

  defp literal_argv?(_), do: false

  defp substitute(argv, sha), do: Enum.map(argv, &String.replace(&1, "{result_sha}", sha))

  defp command_identity(argv), do: "sha256:" <> digest(JSON.encode!(argv))

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp attempt_workspace(attempt) do
    Repo.get!(Consigliere.Workspaces.Workspace, attempt.workspace_id).path
  end

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: value
  defp unwrap_transaction_result({:ok, value}), do: value

  defp unwrap_transaction_result({:error, reason}),
    do: raise("verification write failed: #{inspect(reason)}")
end
