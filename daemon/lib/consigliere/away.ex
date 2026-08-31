defmodule Consigliere.Away do
  @moduledoc """
  Boss AFK marker and return digest. The digest is a query of durable
  Question rows and domain events since the last acknowledged cursor
  (ADR-005). questions.inbox does not acknowledge; away.return does.
  """

  import Ecto.Query

  alias Consigliere.BossCursors.BossCursor
  alias Consigliere.DatabaseWriter
  alias Consigliere.DomainEvents.DomainEvent
  alias Consigliere.Harness.Redaction
  alias Consigliere.Home
  alias Consigliere.Missions.Mission
  alias Consigliere.Questions.Question
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.V0.Limits

  @cursor "boss"
  @max_rows 32
  @max_text_bytes 4_096

  def path(home \\ Home.dir()), do: Path.join(home, "away")

  def mark(home \\ Home.dir()) do
    Home.ensure_dir!(home)
    File.write!(path(home), DateTime.to_iso8601(DateTime.utc_now()))
    upsert_cursor(%{away_since: Txn.now(), acknowledged_at: nil})
    :ok
  end

  def marked?(home \\ Home.dir()), do: File.exists?(path(home))

  def return(home \\ Home.dir()) do
    digest = digest(:return)
    frame_bytes = Limits.frame_bytes()
    acknowledged_event_id = digest_cursor(digest)

    case Limits.encoded_size(digest) do
      {:ok, size} ->
        if size <= frame_bytes do
          case ack_cursor(acknowledged_event_id) do
            {:ok, _} ->
              File.rm(path(home))
              digest

            {:error, _reason} ->
              {:error, :cursor_acknowledgement_failed}
          end
        else
          {:error, :response_too_large}
        end

      _ ->
        {:error, :response_too_large}
    end
  end

  def digest(mode \\ :inbox) do
    cursor = load_cursor()
    questions = open_questions()
    events = if mode == :return, do: events_since(cursor.last_event_id), else: []
    missions = open_missions()

    %{
      "away" => marked?(),
      "cursor" => cursor.last_event_id,
      "questions" => Enum.map(questions, &question_payload/1),
      "events" => events,
      "missions" => missions
    }
  end

  defp open_questions do
    Repo.all(
      from(q in Question,
        where: q.status in ["open", "routed"],
        order_by: [asc: q.inserted_at, asc: q.id],
        limit: ^@max_rows
      )
    )
    |> Enum.uniq_by(& &1.id)
  end

  defp open_missions do
    Repo.all(
      from(m in Mission,
        where: m.phase not in ["completed", "canceled", "superseded"],
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: ^@max_rows,
        select: %{id: m.id, phase: m.phase, objective: m.objective}
      )
    )
    |> Enum.map(fn m ->
      %{
        "id" => m.id,
        "phase" => m.phase,
        "objective" => m.objective |> Redaction.text() |> String.slice(0, @max_text_bytes)
      }
    end)
  end

  defp events_since(last_id) do
    Repo.all(
      from(e in DomainEvent,
        where: e.id > ^last_id,
        order_by: [asc: e.id],
        limit: ^@max_rows,
        select: %{id: e.id, type: e.type, subject_type: e.subject_type, subject_id: e.subject_id}
      )
    )
    |> Enum.map(fn e ->
      %{
        "id" => e.id,
        "type" => e.type,
        "subject_type" => e.subject_type,
        "subject_id" => e.subject_id
      }
    end)
  end

  defp question_payload(q) do
    %{
      "id" => q.id,
      "status" => q.status,
      "prompt" => q.prompt |> Redaction.text() |> String.slice(0, @max_text_bytes),
      "requested_authority" => q.requested_authority,
      "mission_id" => q.mission_id
    }
  end

  defp load_cursor do
    case Repo.get_by(BossCursor, name: @cursor) do
      nil -> %BossCursor{name: @cursor, last_event_id: 0}
      row -> row
    end
  end

  defp upsert_cursor(attrs) do
    DatabaseWriter.transaction(fn ->
      now_id = latest_event_id()
      attrs = Map.put_new(attrs, :last_event_id, now_id)

      case Repo.get_by(BossCursor, name: @cursor) do
        nil ->
          Txn.insert!(BossCursor.changeset(%BossCursor{name: @cursor}, attrs))

        row ->
          Txn.update!(BossCursor.changeset(row, attrs))
      end
    end)
  end

  defp digest_cursor(%{"cursor" => cursor, "events" => events}) do
    case List.last(events) do
      %{"id" => event_id} -> event_id
      _ -> cursor
    end
  end

  @doc false
  def acknowledge_cursor(last_event_id), do: ack_cursor(last_event_id)

  defp ack_cursor(last_event_id) do
    DatabaseWriter.transaction(fn ->
      now = Txn.now()

      query =
        from(c in BossCursor,
          where: c.name == ^@cursor,
          update: [
            set: [
              last_event_id: fragment("MAX(last_event_id, ?)", ^last_event_id),
              away_since: nil,
              acknowledged_at: ^now,
              updated_at: ^now
            ]
          ]
        )

      {updated, _} = Repo.update_all(query, [])

      if updated == 1 do
        :ok
      else
        upsert_cursor(%{
          last_event_id: last_event_id,
          away_since: nil,
          acknowledged_at: now
        })
      end
    end)
  end

  defp latest_event_id do
    Repo.one(from(e in DomainEvent, select: max(e.id))) || 0
  end
end
