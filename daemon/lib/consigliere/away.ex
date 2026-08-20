defmodule Consigliere.Away do
  @moduledoc """
  Boss AFK marker and return digest. The digest is a query of durable
  Question rows, never an in-memory wait list (ADR-005).
  """

  import Ecto.Query

  alias Consigliere.Home
  alias Consigliere.Questions.Question
  alias Consigliere.Repo

  def path(home \\ Home.dir()), do: Path.join(home, "away")

  def mark(home \\ Home.dir()) do
    Home.ensure_dir!(home)
    File.write!(path(home), DateTime.to_iso8601(DateTime.utc_now()))
    :ok
  end

  def marked?(home \\ Home.dir()), do: File.exists?(path(home))

  def return(home \\ Home.dir()) do
    File.rm(path(home))
    digest()
  end

  def digest do
    questions =
      Repo.all(
        from q in Question,
          where: q.status in ["open", "routed"],
          order_by: [asc: q.inserted_at]
      )

    %{
      "away" => false,
      "questions" =>
        questions
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(fn q ->
          %{
            "id" => q.id,
            "status" => q.status,
            "prompt" => q.prompt,
            "requested_authority" => q.requested_authority,
            "mission_id" => q.mission_id
          }
        end)
    }
  end
end
