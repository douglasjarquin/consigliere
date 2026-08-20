defmodule Consigliere.Release do
  @moduledoc """
  Release-time migrate/rollback. Mix is not loaded in a real OTP release.
  """

  @app :consigliere_daemon

  def migrate do
    load()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Consigliere.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end

  def rollback(version) do
    load()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Consigliere.Repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp load do
    Application.load(@app)
    Consigliere.Home.ensure_dir!()
  end
end
