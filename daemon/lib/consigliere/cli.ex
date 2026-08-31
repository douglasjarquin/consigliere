defmodule Consigliere.CLI do
  @moduledoc false

  alias Consigliere.API.Client
  alias Consigliere.Home

  def main(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help])

    if opts[:help] do
      usage()
      0
    else
      dispatch(rest)
    end
  end

  defp dispatch(["ping" | _]), do: print_json(Client.request("ping"))
  defp dispatch(["doctor" | _]), do: doctor()
  defp dispatch(["away" | _]), do: print_json(Client.request("away.mark"))
  defp dispatch(["return" | _]), do: print_json(Client.request("away.return"))
  defp dispatch(["inbox" | _]), do: print_json(Client.request("questions.inbox"))
  defp dispatch(["migrate" | _]), do: migrate()
  defp dispatch(["start" | _]), do: start_daemon()
  defp dispatch(["stop" | _]), do: stop_daemon()
  defp dispatch(["cutover" | _]), do: cutover()

  defp dispatch(["mission", "create" | rest]) do
    payload = mission_create_payload(rest)
    print_json(Client.request("mission.create", payload))
  end

  defp dispatch(["project", "add" | rest]) do
    payload = project_add_payload(rest)
    print_json(Client.request("project.add", payload))
  end

  defp dispatch(["project", "list" | _]), do: print_json(Client.request("project.list"))

  defp dispatch(["help" | _]) do
    usage()
    0
  end

  defp dispatch([]) do
    usage()
    1
  end

  defp dispatch(other) do
    IO.puts(:stderr, "unknown command: #{Enum.join(other, " ")}")
    usage()
    1
  end

  defp usage do
    IO.puts("""
    cs - consigliere boss client
    csd start|stop|migrate - daemon

    cs ping
    cs doctor
    cs away
    cs return
    cs inbox
    cs mission create --project-id ID --objective TEXT --scope TEXT --acceptance TEXT
    cs project add --name NAME --path PATH
    cs project list
    """)
  end

  defp print_json(map) do
    IO.puts(JSON.encode!(map))
    if map["ok"] == false, do: 1, else: 0
  end

  defp mission_create_payload(rest) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [project_id: :string, objective: :string, scope: :string, acceptance: :string]
      )

    %{
      "project_id" => opts[:project_id],
      "objective" => opts[:objective],
      "scope" => opts[:scope],
      "acceptance_criteria" => opts[:acceptance]
    }
  end

  defp project_add_payload(rest) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [name: :string, path: :string, url: :string, branch: :string]
      )

    path = opts[:path]
    url = opts[:url] || (path && "file://#{Path.expand(path)}")

    %{
      "name" => opts[:name],
      "repository_path" => path,
      "repository_url" => url,
      "default_branch" => opts[:branch] || "main"
    }
  end

  defp migrate do
    :ok = Consigliere.Release.migrate()
    IO.puts("migrated #{Home.database_path()}")
    0
  end

  defp start_daemon do
    {:ok, _} = Application.ensure_all_started(:consigliere_daemon)
    IO.puts("csd started home=#{Home.dir()}")
    Process.sleep(:infinity)
  end

  defp stop_daemon do
    _ = Application.stop(:consigliere_daemon)
    IO.puts("csd stopped")
    0
  end

  # Plain IO.puts, not Mix.shell(): this must run from `bin/consigliere_daemon
  # eval` in a real release, where Mix is not loaded.
  def doctor do
    home = Home.dir()
    IO.puts("home: #{home}")
    IO.puts("database: #{Home.database_path(home)}")
    IO.puts("lock: #{Home.lock_path(home)} #{lock_word(home)}")

    case Home.socket_status(home) do
      :live ->
        IO.puts("probe socket: live (#{Home.boss_socket_path(home)})")

      :stale ->
        IO.puts("probe socket: stale (#{Home.boss_socket_path(home)})")

      :absent ->
        IO.puts("probe socket: absent")
    end

    case Home.last_error(home) do
      nil -> :ok
      reason -> IO.puts("last startup failure: #{reason}")
    end

    IO.puts("codex auth: #{Home.codex_auth_status(home)}")

    case Home.storage_diagnostic(home) do
      :ok -> IO.puts("storage: ok")
      {:error, reason} -> IO.puts("storage: error code=#{reason}")
    end
  end

  defp lock_word(home) do
    case Home.lock_status(home) do
      {:held, pid} -> "held pid=#{pid}"
      :stale -> "stale"
      :unowned -> "unowned"
    end
  end

  def away do
    Consigliere.Away.mark()
    IO.puts("away")
  end

  def return do
    case Consigliere.Away.return() do
      %{"questions" => questions} ->
        IO.puts("return: #{length(questions)} open question(s)")

        Enum.each(questions, fn q ->
          IO.puts("- #{q["id"]} #{q["prompt"]}")
        end)

      {:error, reason} ->
        IO.puts("return failed: #{reason}")
    end
  end

  def cutover do
    IO.puts(File.read!(runbook_path()))
  end

  def runbook_path do
    Path.expand(Path.join([__DIR__, "..", "..", "..", "docs", "cutover.md"]))
  end
end
