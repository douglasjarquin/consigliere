defmodule Consigliere.API.Protocol do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.API.Auth
  alias Consigliere.Actor
  alias Consigliere.CommandReceipts
  alias Consigliere.Attempts
  alias Consigliere.DispatchOperations.DispatchOperation
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Away
  alias Consigliere.Questions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  @version 1
  @attempt_ops Consigliere.Capabilities.worker_operations()
  @review_phases ~w(awaiting_authorization ready_for_review
                    awaiting_integration_authorization failed)

  def handle(line, bound \\ :unbound) when is_binary(line) do
    case JSON.decode(String.trim(line)) do
      {:ok, req} when is_map(req) -> encode(dispatch(req, bound))
      _ -> encode(%{"v" => @version, "ok" => false, "error" => error("invalid", "not json")})
    end
  end

  defp dispatch(%{"v" => v, "id" => id}, _bound) when v != @version do
    fail(id, "protocol_version", "unsupported version #{inspect(v)}")
  end

  defp dispatch(%{"v" => @version, "id" => id, "op" => op} = req, bound) do
    case Auth.identify(req, bound) do
      {:error, reason} ->
        fail(id, "unauthorized", reason)

      actor ->
        payload = Map.get(req, "payload", %{})

        case validate_request_contract(req, actor, op, payload, id) do
          :ok -> run_maybe_once(op, payload, actor, req, id)
          {:error, reason} -> fail(id, "invalid", reason)
        end
    end
  end

  defp dispatch(%{"id" => id}, _bound), do: fail(id, "invalid", "missing v or op")
  defp dispatch(_, _bound), do: fail(nil, "invalid", "missing id")

  defp run_maybe_once(op, payload, actor, req, id) do
    if Consigliere.Operations.mutating?(op) do
      key = req["idempotency_key"] || id

      CommandReceipts.remember(actor, op, key, payload, fn ->
        run(op, execution_payload(op, payload, key, id), actor)
      end)
      |> wrap(id)
    else
      run(op, payload, actor) |> wrap(id)
    end
  end

  defp run(op, payload, %Actor{principal: "attempt", allowed_ops: ops} = actor)
       when is_list(ops) do
    if op in @attempt_ops and op in ops do
      run_allowed(op, payload, actor)
    else
      {:error, {:unauthorized, :capability}}
    end
  end

  defp run(op, _payload, %Actor{principal: "attempt"}) when op not in @attempt_ops do
    {:error, {:unauthorized, :capability}}
  end

  defp run(_op, _payload, %Actor{principal: "attempt", allowed_ops: nil}) do
    {:error, {:unauthorized, :capability}}
  end

  defp run(op, payload, actor), do: run_allowed(op, payload, actor)

  defp validate_request_contract(req, actor, op, payload, fallback_id) do
    version = req["operation_version"]
    canonical_hash = req["canonical_hash"]

    if is_nil(version) and is_nil(canonical_hash) do
      :ok
    else
      key = req["idempotency_key"] || fallback_id

      with {:ok, expected_version} <- Consigliere.Operations.version(op),
           true <- version in [nil, expected_version],
           :ok <- verify_canonical_hash(canonical_hash, actor, op, key, payload) do
        :ok
      else
        false -> {:error, "operation_version_mismatch"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp verify_canonical_hash(nil, _actor, _op, _key, _payload), do: :ok

  defp verify_canonical_hash(hash, actor, op, key, payload) when is_binary(hash) do
    case CommandReceipts.request_hash(actor, op, key, payload) do
      {:ok, ^hash} -> :ok
      {:ok, _other} -> {:error, "canonical_request_mismatch"}
      {:error, _reason} -> :ok
    end
  end

  defp verify_canonical_hash(_hash, _actor, _op, _key, _payload),
    do: {:error, "canonical_request_invalid"}

  defp run_allowed("ping", _payload, _actor), do: {:ok, %{"pong" => true}}

  defp run_allowed("health", _payload, actor) do
    with :ok <- require_reader(actor) do
      {:ok, health_payload()}
    end
  end

  defp run_allowed("version", _payload, actor) do
    with :ok <- require_reader(actor) do
      {:ok,
       %{
         "protocol" => @version,
         "release" => release_version()
       }}
    end
  end

  defp run_allowed("mission.create", payload, actor) do
    project_id = payload["project_id"]

    if is_binary(project_id) and project_id != "" do
      Missions.create(
        %{
          objective: payload["objective"],
          scope: payload["scope"],
          acceptance_criteria: payload["acceptance_criteria"],
          project_id: project_id
        },
        actor
      )
      |> ok_mission()
    else
      {:error, {:invalid, "project_id required"}}
    end
  end

  defp run_allowed("project.add", payload, actor) do
    Consigliere.Projects.register(
      %{
        name: payload["name"],
        repository_path: payload["repository_path"],
        repository_url: payload["repository_url"],
        default_branch: payload["default_branch"] || "main"
      },
      actor
    )
    |> case do
      {:ok, project} ->
        {:ok,
         %{
           "id" => project.id,
           "name" => project.name,
           "repository_url" => project.repository_url,
           "default_branch" => project.default_branch,
           "base_ref" => project.base_ref,
           "base_sha" => project.base_sha
         }}

      other ->
        other
    end
  end

  defp run_allowed("project.list", _payload, actor) do
    with :ok <- require_reader(actor) do
      projects = Repo.all(Consigliere.Projects.Project)

      {:ok,
       %{
         "projects" =>
           Enum.map(projects, fn p ->
             %{"id" => p.id, "name" => p.name, "repository_url" => p.repository_url}
           end)
       }}
    end
  end

  defp run_allowed("project.get", payload, actor) do
    with :ok <- require_reader(actor) do
      case Repo.get(Consigliere.Projects.Project, payload["project_id"]) do
        nil ->
          {:error, {:not_found, "project"}}

        project ->
          {:ok,
           %{
             "id" => project.id,
             "name" => project.name,
             "repository_url" => project.repository_url,
             "default_branch" => project.default_branch,
             "base_ref" => project.base_ref,
             "base_sha" => project.base_sha
           }}
      end
    end
  end

  defp run_allowed("mission.submit", payload, actor) do
    Missions.submit_for_authorization(payload["mission_id"], actor) |> ok_mission()
  end

  defp run_allowed("mission.request_changes", payload, actor) do
    Missions.request_changes(payload["mission_id"], actor, payload["reason"]) |> ok_mission()
  end

  defp run_allowed("mission.grant_work", payload, actor) do
    Missions.grant_work_authorization_command(
      payload["mission_id"],
      actor,
      %{
        idempotency_key: payload["_idempotency_key"],
        correlation_id: payload["_correlation_id"]
      }
    )
    |> ok_mission()
  end

  defp run_allowed("mission.cancel", payload, actor) do
    Missions.cancel(payload["mission_id"], actor, payload["reason"] || "canceled") |> ok_mission()
  end

  defp run_allowed("mission.pause", payload, actor) do
    Missions.pause(payload["mission_id"], actor, payload["reason"] || "boss pause")
    |> ok_mission()
  end

  defp run_allowed("mission.resume", payload, actor) do
    Missions.resume(payload["mission_id"], actor) |> ok_mission()
  end

  defp run_allowed("mission.list", _payload, actor) do
    with :ok <- require_reader(actor) do
      missions =
        Repo.all(from(m in Mission, order_by: [desc: m.inserted_at]))

      {:ok, %{"missions" => Enum.map(missions, &mission_summary/1)}}
    end
  end

  defp run_allowed("mission.why", payload, actor) do
    with :ok <- require_reader(actor) do
      why_mission(payload["mission_id"], actor)
    end
  end

  defp run_allowed("mission.review", _payload, actor) do
    with :ok <- require_reader(actor) do
      missions =
        Repo.all(
          from(m in Mission,
            where: m.phase in ^@review_phases,
            order_by: [asc: m.inserted_at]
          )
        )

      {:ok, %{"missions" => Enum.map(missions, &mission_summary/1)}}
    end
  end

  defp run_allowed("attempt.list", _payload, actor) do
    with :ok <- require_reader(actor) do
      attempts =
        Repo.all(
          from(a in Consigliere.Attempts.Attempt, order_by: [desc: a.inserted_at], limit: 100)
        )

      {:ok,
       %{
         "attempts" =>
           Enum.map(attempts, fn a ->
             %{
               "id" => a.id,
               "mission_id" => a.mission_id,
               "status" => a.status,
               "role" => a.role,
               "harness" => a.harness
             }
           end)
       }}
    end
  end

  defp run_allowed("attempt.logs", payload, actor) do
    with :ok <- require_reader(actor) do
      attempt_logs(payload["attempt_id"])
    end
  end

  defp run_allowed("incident.list", _payload, actor) do
    with :ok <- require_reader(actor) do
      incidents =
        Repo.all(
          from(i in Consigliere.Incidents.Incident, order_by: [desc: i.inserted_at], limit: 100)
        )

      {:ok,
       %{
         "incidents" =>
           Enum.map(incidents, fn i ->
             %{
               "id" => i.id,
               "mission_id" => i.mission_id,
               "severity" => i.severity,
               "reason" => i.reason
             }
           end)
       }}
    end
  end

  defp run_allowed("event.list", _payload, actor) do
    with :ok <- require_reader(actor) do
      events =
        Repo.all(
          from(e in Consigliere.DomainEvents.DomainEvent,
            order_by: [desc: e.id],
            limit: 100
          )
        )

      {:ok,
       %{
         "events" =>
           Enum.map(events, fn e ->
             %{
               "id" => e.id,
               "type" => e.type,
               "subject_type" => e.subject_type,
               "subject_id" => e.subject_id,
               "occurred_at" => datetime_to_iso(e.occurred_at)
             }
           end)
       }}
    end
  end

  defp run_allowed("reconcile", _payload, actor) do
    if actor.principal == "boss" do
      results = Consigliere.Reconciler.run()
      {:ok, %{"count" => length(results)}}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run_allowed("daemon.shutdown", _payload, actor) do
    if actor.principal == "boss" do
      request_stop()
      {:ok, %{"stopping" => true}}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run_allowed("mission.grant_integration", payload, actor) do
    Missions.grant_integration_authorization(payload["mission_id"], actor, %{
      target_sha: payload["target_sha"],
      target_pull_request: payload["target_pull_request"]
    })
    |> ok_mission()
  end

  defp run_allowed("mission.get", payload, actor) do
    case Repo.get(Mission, payload["mission_id"]) do
      nil ->
        {:error, {:not_found, "mission"}}

      mission ->
        if actor.principal == "attempt" and not own_mission?(actor, mission) do
          {:error, {:unauthorized, :scope}}
        else
          blockers =
            Repo.all(
              from(b in MissionBlocker,
                where: b.mission_id == ^mission.id and b.status == "open"
              )
            )

          {:ok,
           %{
             "id" => mission.id,
             "phase" => mission.phase,
             "objective" => mission.objective,
             "scope" => mission.scope,
             "acceptance_criteria" => mission.acceptance_criteria,
             "project_id" => mission.project_id,
             "base_sha" => mission.base_sha,
             "authorization_id" => mission.authorization_id,
             "blockers" =>
               Enum.map(blockers, fn b ->
                 %{"kind" => b.kind, "reason" => b.reason, "subject_id" => b.subject_id}
               end)
           }}
        end
    end
  end

  defp run_allowed("mission.get_own", payload, %Actor{principal: "attempt"} = actor) do
    run_allowed("mission.get", payload, actor)
  end

  defp run_allowed("mission.get_own", _payload, _actor),
    do: {:error, {:unauthorized, :capability}}

  defp run_allowed("attempt.progress", payload, actor) do
    Attempts.report_progress(payload["attempt_id"], actor, payload)
    |> ok_attempt()
  end

  defp run_allowed("attempt.checkpoint", payload, actor) do
    Attempts.request_checkpoint(payload["attempt_id"], actor, %{
      reported_checkpoint_sha: payload["reported_checkpoint_sha"] || payload["checkpoint_sha"]
    })
    |> ok_attempt()
  end

  defp run_allowed("attempt.complete", payload, actor) do
    Attempts.report_completion(payload["attempt_id"], actor)
    |> ok_attempt()
  end

  defp run_allowed("attempt.fail", payload, actor) do
    Attempts.report_failure(payload["attempt_id"], actor, %{
      classification: payload["classification"]
    })
    |> ok_attempt()
  end

  defp run_allowed("question.open", payload, actor) do
    Questions.open(
      %{
        attempt_id: payload["attempt_id"] || actor.attempt_id,
        request_id: payload["request_id"] || payload["idempotency_key"],
        blocking_scope: payload["blocking_scope"],
        requested_authority: payload["requested_authority"],
        prompt: payload["prompt"]
      },
      actor
    )
    |> ok_question()
  end

  defp run_allowed("question.answer", payload, actor) do
    Questions.answer(payload["question_id"], actor, %{
      answer: payload["answer"],
      answer_channel: payload["answer_channel"] || actor.channel
    })
    |> ok_question()
  end

  defp run_allowed("away.mark", _payload, actor) do
    if actor.principal == "boss" do
      Away.mark()
      {:ok, %{"away" => true}}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run_allowed("away.return", _payload, actor) do
    if actor.principal == "boss" do
      {:ok, Away.return()}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run_allowed("questions.inbox", _payload, actor) do
    if actor.principal not in ["boss", "daemon", "model_advisory"] do
      {:error, {:unauthorized, :principal}}
    else
      questions =
        Repo.all(
          from(q in Question,
            where: q.status in ["open", "routed"],
            order_by: [asc: q.inserted_at]
          )
        )

      {:ok,
       %{
         "questions" =>
           Enum.map(questions, fn q ->
             %{
               "id" => q.id,
               "status" => q.status,
               "prompt" => q.prompt,
               "requested_authority" => q.requested_authority,
               "mission_id" => q.mission_id
             }
           end)
       }}
    end
  end

  defp run_allowed(_op, _payload, _actor), do: {:error, {:invalid, "unknown op"}}

  defp execution_payload("mission.grant_work", payload, key, correlation_id) do
    Map.merge(payload, %{
      "_idempotency_key" => key,
      "_correlation_id" => correlation_id
    })
  end

  defp execution_payload(_op, payload, _key, _correlation_id), do: payload

  defp own_mission?(%Actor{attempt_id: nil}, _), do: false

  defp own_mission?(%Actor{attempt_id: attempt_id}, mission) do
    case Repo.get(Consigliere.Attempts.Attempt, attempt_id) do
      %{mission_id: id} -> id == mission.id
      _ -> false
    end
  end

  defp ok_mission({:ok, %{mission: mission, status: status} = result}) do
    {:ok,
     mission_payload(mission)
     |> Map.merge(%{
       "pause_status" => to_string(status),
       "checkpoint_sha" => Map.get(result, :checkpoint_sha)
     })}
  end

  defp ok_mission({:ok, %{id: _id} = mission}), do: {:ok, mission_payload(mission)}

  defp ok_mission({:ok, %{mission: mission}}), do: {:ok, mission_payload(mission)}

  defp ok_mission(other), do: other

  defp ok_question({:ok, %{id: id, status: status}}), do: {:ok, %{"id" => id, "status" => status}}
  defp ok_question(other), do: other

  defp ok_attempt({:ok, %{id: id, status: status}}),
    do: {:ok, %{"id" => id, "status" => status}}

  defp ok_attempt(other), do: other

  defp mission_payload(mission) do
    %{
      "id" => mission.id,
      "phase" => mission.phase,
      "project_id" => mission.project_id,
      "objective" => mission.objective,
      "scope" => mission.scope,
      "acceptance_criteria" => mission.acceptance_criteria,
      "base_sha" => mission.base_sha,
      "authorization_id" => mission.authorization_id
    }
  end

  defp wrap({:ok, :replay, envelope}, id) when is_map(envelope) do
    Map.put(envelope, "id", id)
  end

  defp wrap(result, id) do
    result
    |> CommandReceipts.result_envelope()
    |> Map.put("id", id)
  end

  defp fail(id, code, reason) do
    %{
      "v" => @version,
      "id" => id,
      "ok" => false,
      "error" => error(code, reason)
    }
  end

  defp error(code, reason) do
    %{
      "code" => code,
      "reason" => reason |> to_string() |> String.slice(0, 512)
    }
  end

  defp encode(map), do: JSON.encode!(map)

  defp request_stop do
    if Application.get_env(:consigliere_daemon, :halt_on_shutdown, true) do
      spawn(fn ->
        Process.sleep(50)
        System.stop(0)
      end)
    end

    :ok
  end

  defp require_reader(%Actor{principal: p}) when p in ["boss", "daemon", "model_advisory"],
    do: :ok

  defp require_reader(_), do: {:error, {:unauthorized, :principal}}

  defp health_payload do
    runner = runner_info()

    %{
      "status" => "ok",
      "protocol" => @version,
      "release" => release_version(),
      "schema" => schema_version(),
      "harness" => inspect(Consigliere.Adapters.harness()),
      "made" => inspect(Consigliere.Adapters.made()),
      "github" => inspect(Consigliere.Adapters.github()),
      "runner" => runner,
      "sockets" => %{
        "boss" => to_string(Consigliere.Home.socket_status()),
        "api" => to_string(Consigliere.Home.probe(Consigliere.Home.api_socket_path())),
        "priv" => to_string(Consigliere.Home.probe(Consigliere.Home.privileged_socket_path()))
      }
    }
  end

  defp release_version do
    to_string(Application.spec(:consigliere_daemon, :vsn) || "dev")
  end

  defp schema_version do
    case Ecto.Migrator.migrated_versions(Repo) do
      [] -> 0
      versions -> List.last(versions)
    end
  end

  defp runner_info do
    path = Path.join(:code.priv_dir(:consigliere_daemon), "cs-runner")
    %{"path" => path, "present" => File.exists?(path)}
  rescue
    _ -> %{"path" => nil, "present" => false}
  end

  defp mission_summary(mission) do
    %{
      "id" => mission.id,
      "phase" => mission.phase,
      "objective" => mission.objective,
      "project_id" => mission.project_id
    }
  end

  defp why_mission(nil, _actor), do: {:error, {:invalid, "mission_id required"}}

  defp why_mission(mission_id, actor) do
    case Repo.get(Mission, mission_id) do
      nil ->
        {:error, {:not_found, "mission"}}

      mission ->
        if actor.principal == "attempt" and not own_mission?(actor, mission) do
          {:error, {:unauthorized, :scope}}
        else
          blockers =
            Repo.all(
              from(b in MissionBlocker,
                where: b.mission_id == ^mission.id and b.status == "open"
              )
            )

          occupying_statuses = Consigliere.AttemptStates.occupying()

          occupying =
            Repo.all(
              from(a in Consigliere.Attempts.Attempt,
                where:
                  a.mission_id == ^mission.id and
                    a.status in ^occupying_statuses
              )
            )

          {runnable, reason} = why_runnability(mission, blockers, occupying)
          dispatch = dispatch_summary(mission.id)
          reason = durable_dispatch_reason(dispatch, reason)

          {:ok,
           %{
             "id" => mission.id,
             "phase" => mission.phase,
             "objective" => mission.objective,
             "runnable" => runnable,
             "reason" => Atom.to_string(reason),
             "next_step" => Atom.to_string(reason),
             "phase_reason" => phase_reason(mission.phase),
             "dispatch" => dispatch,
             "blockers" =>
               Enum.map(blockers, fn b ->
                 %{
                   "kind" => b.kind,
                   "reason" => b.reason,
                   "subject_id" => b.subject_id,
                   "status" => b.status
                 }
               end)
           }}
        end
    end
  end

  defp why_runnability(mission, blockers, occupying) do
    cond do
      mission.phase not in ["authorized", "active"] ->
        {false, :phase}

      blockers != [] ->
        {false, :blocked}

      occupying != [] ->
        {false, :occupying}

      mission.phase == "authorized" ->
        {true, :ready}

      true ->
        case Consigliere.Progression.next_action(mission) do
          :none -> {false, :waiting}
          action -> {false, action}
        end
    end
  end

  defp dispatch_summary(mission_id) do
    operation =
      Repo.one(
        from(o in DispatchOperation,
          where: o.mission_id == ^mission_id,
          order_by: [desc: o.inserted_at],
          limit: 1
        )
      )

    case operation do
      nil ->
        nil

      operation ->
        attempt = Repo.get(Consigliere.Attempts.Attempt, operation.attempt_id)

        workspace =
          operation.workspace_id &&
            Repo.get(Consigliere.Workspaces.Workspace, operation.workspace_id)

        %{
          "id" => operation.id,
          "correlation_id" => operation.correlation_id,
          "idempotency_key" => operation.idempotency_key,
          "status" => operation.status,
          "slot_state" => operation.slot_state,
          "child_start_state" => operation.child_start_state,
          "attempt_id" => operation.attempt_id,
          "attempt_status" => attempt && attempt.status,
          "workspace_id" => operation.workspace_id,
          "workspace_path" => workspace && workspace.path,
          "workspace_generation" => operation.workspace_generation,
          "base_sha" => operation.base_sha,
          "parent_checkpoint_sha" => operation.parent_checkpoint_sha,
          "runner_pid" => attempt && attempt.runner_pid,
          "harness_pid" => attempt && attempt.harness_pid,
          "process_group" => attempt && attempt.pgid,
          "last_error" => bounded_detail(operation.last_error)
        }
    end
  end

  defp durable_dispatch_reason(%{"status" => "unknown"}, _reason), do: :unknown
  defp durable_dispatch_reason(%{"status" => "failed"}, _reason), do: :dispatch_failed
  defp durable_dispatch_reason(%{"status" => "completed"}, _reason), do: :dispatch_completed

  defp durable_dispatch_reason(
         %{"attempt_status" => status},
         _reason
       )
       when status in ["completed", "failed", "lost", "canceled", "superseded"],
       do: :dispatch_terminal

  defp durable_dispatch_reason(_dispatch, reason), do: reason

  defp bounded_detail(nil), do: nil
  defp bounded_detail(value), do: value |> to_string() |> String.slice(0, 512)

  defp phase_reason("draft"), do: "not submitted for authorization"
  defp phase_reason("awaiting_authorization"), do: "no work authorization yet"
  defp phase_reason("authorized"), do: "authorized, waiting to start"
  defp phase_reason("active"), do: "active"
  defp phase_reason("paused"), do: "paused by boss"
  defp phase_reason("ready_for_review"), do: "waiting on boss review"

  defp phase_reason("awaiting_integration_authorization"),
    do: "waiting on integration authorization"

  defp phase_reason("integrating"), do: "integration in progress"
  defp phase_reason("completed"), do: "completed"
  defp phase_reason("failed"), do: "failed; needs an explicit decision"
  defp phase_reason("canceled"), do: "canceled"
  defp phase_reason("superseded"), do: "superseded"
  defp phase_reason(other), do: other

  defp attempt_logs(nil), do: {:error, {:invalid, "attempt_id required"}}

  defp attempt_logs(attempt_id) do
    case Repo.get(Consigliere.Attempts.Attempt, attempt_id) do
      nil ->
        {:error, {:not_found, "attempt"}}

      attempt ->
        path = Path.join(Consigliere.Home.logs_dir(), "attempts/#{attempt.id}.log")
        lines = log_lines(path) ++ harness_event_lines(attempt.id)
        {:ok, %{"attempt_id" => attempt.id, "path" => path, "lines" => lines}}
    end
  end

  defp log_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split("\n", trim: true) |> Enum.take(-200)

      {:error, _} ->
        []
    end
  end

  defp harness_event_lines(attempt_id) do
    Repo.all(
      from(e in Consigliere.HarnessEvents.HarnessEvent,
        where: e.attempt_id == ^attempt_id,
        order_by: [asc: e.native_sequence],
        limit: 200
      )
    )
    |> Enum.map(fn e -> "#{e.native_sequence} #{e.type}" end)
  end

  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp datetime_to_iso(other), do: to_string(other)
end
