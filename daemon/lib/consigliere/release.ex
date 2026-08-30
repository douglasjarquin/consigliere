defmodule Consigliere.Release do
  @moduledoc """
  Release-time migrate/rollback. Mix is not loaded in a real OTP release.
  """

  @app :consigliere_daemon

  def migrate do
    load()

    with_home_lock(fn ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          Consigliere.Repo,
          &Ecto.Migrator.run(&1, :up, all: true),
          pool_size: 1
        )

      :ok
    end)
  end

  def rollback(version) do
    load()

    with_home_lock(fn ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          Consigliere.Repo,
          &Ecto.Migrator.run(&1, :down, to: version),
          pool_size: 1
        )

      :ok
    end)
  end

  defp load do
    Application.load(@app)
  end

  defp with_home_lock(fun) do
    case Consigliere.Home.Lock.with_lock(Consigliere.Home.dir(), fun) do
      {:ok, result} ->
        result

      {:error, :already_running} ->
        raise "CS_HOME already owned by another daemon"

      {:error, reason} ->
        raise "unable to lock CS_HOME: #{inspect(reason)}"
    end
  end
end
