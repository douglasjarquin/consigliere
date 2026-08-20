defmodule Consigliere.API.Protocol do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.Away
  alias Consigliere.Questions
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  @version 1

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
    case bind_actor(actor(req), bound) do
      {:error, reason} ->
        fail(id, "unauthorized", reason)

      actor ->
        req
        |> Map.get("payload", %{})
        |> then(&run(op, &1, actor))
        |> wrap(id)
    end
  end

  defp dispatch(%{"id" => id}, _bound), do: fail(id, "invalid", "missing v or op")
  defp dispatch(_, _bound), do: fail(nil, "invalid", "missing id")

  defp actor(%{"actor" => %{"principal" => principal} = raw}) when is_binary(principal) do
    %Actor{
      principal: principal,
      attempt_id: raw["attempt_id"],
      fencing_token: raw["fencing_token"],
      channel: raw["channel"] || default_channel(principal)
    }
  end

  defp actor(_), do: {:error, "missing actor.principal"}

  defp bind_actor({:error, reason}, _bound), do: {:error, reason}
  defp bind_actor(actor, :unbound), do: actor
  defp bind_actor(%{principal: "boss"} = actor, :privileged), do: actor
  defp bind_actor(_actor, :privileged), do: {:error, "privileged socket requires boss"}

  defp bind_actor(%{principal: "boss"}, :capability),
    do: {:error, "capability socket cannot carry boss"}

  defp bind_actor(actor, :capability), do: actor

  defp default_channel("boss"), do: "privileged"
  defp default_channel("attempt"), do: "capability"
  defp default_channel("daemon"), do: "internal"
  defp default_channel(_), do: "advisory"

  defp run("ping", _payload, _actor), do: {:ok, %{"pong" => true}}

  defp run("mission.create", payload, actor) do
    Missions.create(
      %{
        objective: payload["objective"],
        scope: payload["scope"],
        acceptance_criteria: payload["acceptance_criteria"]
      },
      actor
    )
    |> ok_mission()
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
