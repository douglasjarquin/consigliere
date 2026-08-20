defmodule Consigliere.API.Protocol do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.API.Auth
  alias Consigliere.Actor
  alias Consigliere.CommandReceipts
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Away
  alias Consigliere.Questions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  @version 1
  @mutating ~w(mission.create mission.submit mission.grant_work mission.cancel
               mission.grant_integration question.open question.answer away.mark
               away.return project.add)
  @attempt_ops ~w(ping mission.get question.open)

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
        run_maybe_once(op, payload, actor, req, id)
    end
  end

  defp dispatch(%{"id" => id}, _bound), do: fail(id, "invalid", "missing v or op")
  defp dispatch(_, _bound), do: fail(nil, "invalid", "missing id")

  defp run_maybe_once(op, payload, actor, req, id) when op in @mutating do
    key = req["idempotency_key"] || id

    CommandReceipts.remember(actor.principal, op, key, payload, fn ->
      run(op, payload, actor)
    end)
    |> wrap(id)
  end

  defp run_maybe_once(op, payload, actor, _req, id) do
    run(op, payload, actor) |> wrap(id)
  end

  defp run(op, _payload, %Actor{principal: "attempt"}) when op not in @attempt_ops do
    {:error, {:unauthorized, :capability}}
  end

  defp run("ping", _payload, _actor), do: {:ok, %{"pong" => true}}

  defp run("mission.create", payload, actor) do
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

  defp run("project.add", payload, actor) do
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
           "repository_url" => project.repository_url
         }}

      other ->
        other
    end
  end

  defp run("project.list", _payload, actor) do
    if actor.principal in ["boss", "daemon"] do
      projects = Repo.all(Consigliere.Projects.Project)

      {:ok,
       %{
         "projects" =>
           Enum.map(projects, fn p ->
             %{"id" => p.id, "name" => p.name, "repository_url" => p.repository_url}
           end)
       }}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run("project.get", payload, actor) do
    if actor.principal in ["boss", "daemon"] do
      case Repo.get(Consigliere.Projects.Project, payload["project_id"]) do
        nil ->
          {:error, {:not_found, "project"}}

        project ->
          {:ok,
           %{
             "id" => project.id,
             "name" => project.name,
             "repository_url" => project.repository_url,
             "default_branch" => project.default_branch
           }}
      end
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run("mission.submit", payload, actor) do
    Missions.submit_for_authorization(payload["mission_id"], actor) |> ok_mission()
  end

  defp run("mission.grant_work", payload, actor) do
    Missions.grant_work_authorization(payload["mission_id"], actor) |> ok_mission()
  end

  defp run("mission.cancel", payload, actor) do
    Missions.cancel(payload["mission_id"], actor, payload["reason"] || "canceled") |> ok_mission()
  end

  defp run("mission.grant_integration", payload, actor) do
    Missions.grant_integration_authorization(payload["mission_id"], actor, %{
      target_sha: payload["target_sha"],
      target_pull_request: payload["target_pull_request"]
    })
    |> ok_mission()
  end

  defp run("mission.get", payload, actor) do
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
             "blockers" =>
               Enum.map(blockers, fn b ->
                 %{"kind" => b.kind, "reason" => b.reason, "subject_id" => b.subject_id}
               end)
           }}
        end
    end
  end

  defp run("question.open", payload, actor) do
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

  defp run("question.answer", payload, actor) do
    Questions.answer(payload["question_id"], actor, %{
      answer: payload["answer"],
      answer_channel: payload["answer_channel"] || actor.channel
    })
    |> ok_question()
  end

  defp run("away.mark", _payload, actor) do
    if actor.principal == "boss" do
      Away.mark()
      {:ok, %{"away" => true}}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run("away.return", _payload, actor) do
    if actor.principal == "boss" do
      {:ok, Away.return()}
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp run("questions.inbox", _payload, actor) do
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

  defp run(_op, _payload, _actor), do: {:error, {:invalid, "unknown op"}}

  defp own_mission?(%Actor{attempt_id: nil}, _), do: false

  defp own_mission?(%Actor{attempt_id: attempt_id}, mission) do
    case Repo.get(Consigliere.Attempts.Attempt, attempt_id) do
      %{mission_id: id} -> id == mission.id
      _ -> false
    end
  end

  defp ok_mission({:ok, %{id: id, phase: phase}}), do: {:ok, %{"id" => id, "phase" => phase}}

  defp ok_mission({:ok, %{mission: %{id: id, phase: phase}}}),
    do: {:ok, %{"id" => id, "phase" => phase}}

  defp ok_mission(other), do: other

  defp ok_question({:ok, %{id: id, status: status}}), do: {:ok, %{"id" => id, "status" => status}}
  defp ok_question(other), do: other

  defp wrap({:ok, :replay, payload}, id), do: wrap({:ok, payload}, id)

  defp wrap({:ok, payload}, id),
    do: %{"v" => @version, "id" => id, "ok" => true, "payload" => payload}

  defp wrap({:error, {:unauthorized, reason}}, id), do: fail(id, "unauthorized", inspect(reason))

  defp wrap({:error, {:illegal_transition, reason}}, id),
    do: fail(id, "illegal_transition", inspect(reason))

  defp wrap({:error, {:fenced, attempt_id}}, id), do: fail(id, "fenced", attempt_id)
  defp wrap({:error, {:not_found, what}}, id), do: fail(id, "not_found", what)
  defp wrap({:error, {:invalid, reason}}, id), do: fail(id, "invalid", reason)

  defp wrap({:error, %Ecto.Changeset{} = cs}, id) do
    fail(id, "invalid", inspect(Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)))
  end

  defp wrap({:error, other}, id), do: fail(id, "error", inspect(other))

  defp fail(id, code, reason) do
    %{"v" => @version, "id" => id, "ok" => false, "error" => error(code, reason)}
  end

  defp error(code, reason), do: %{"code" => code, "reason" => to_string(reason)}

  defp encode(map), do: JSON.encode!(map)
end
