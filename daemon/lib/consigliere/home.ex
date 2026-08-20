defmodule Consigliere.Home do
  @moduledoc false

  def dir do
    System.get_env("CS_HOME") || Path.expand("~/.consigliere")
  end

  def ensure_dir!(home \\ dir()) do
    prepare_dir!(home)
    ensure_secrets!(home)
    home
  end

  def prepare_dir!(home \\ dir()) do
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    File.mkdir_p!(credentials_dir(home))
    File.mkdir_p!(trusted_projects_dir(home))
    File.mkdir_p!(workspaces_dir(home))
    File.mkdir_p!(runtime_attempts_dir(home))
    File.mkdir_p!(evidence_dir(home))
    File.mkdir_p!(logs_dir(home))
    File.chmod!(credentials_dir(home), 0o700)
    home
  end

  def ensure_secrets!(home \\ dir()) do
    _ = ensure_boss_secret!(home)
    home
  end

  def ensure_boss_secret!(home \\ dir()) do
    File.mkdir_p!(credentials_dir(home))
    File.chmod!(credentials_dir(home), 0o700)
    path = boss_credential_path(home)

    unless File.exists?(path) do
      File.write!(path, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
    end

    File.chmod!(path, 0o600)
    File.read!(path)
  end

  def database_path(home \\ dir()), do: Path.join(home, "consigliere.db")
  def lock_path(home \\ dir()), do: Path.join(home, "lock")
  def owner_path(home \\ dir()), do: Path.join(home, "owner.json")
  def credentials_dir(home \\ dir()), do: Path.join(home, "credentials")
  def trusted_projects_dir(home \\ dir()), do: Path.join(home, "trusted/projects")
  def workspaces_dir(home \\ dir()), do: Path.join(home, "workspaces")
  def runtime_attempts_dir(home \\ dir()), do: Path.join(home, "runtime/attempts")
  def evidence_dir(home \\ dir()), do: Path.join(home, "evidence")
  def logs_dir(home \\ dir()), do: Path.join(home, "logs")
  def boss_credential_path(home \\ dir()), do: Path.join(credentials_dir(home), "boss")

  def boss_socket_path(home \\ dir()), do: Path.join(home, "boss.sock")
  def api_socket_path(home \\ dir()), do: Path.join(home, "api.sock")
  def privileged_socket_path(home \\ dir()), do: Path.join(home, "priv.sock")
  def last_error_path(home \\ dir()), do: Path.join(home, "last_error.log")

  def socket_status(home \\ dir()) do
    probe(boss_socket_path(home))
  end

  def probe(socket_path) do
    if File.exists?(socket_path) do
      case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 200) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :live

        {:error, _} ->
          :stale
      end
    else
      :absent
    end
  end

  def write_owner!(home \\ dir()) do
    payload =
      JSON.encode!(%{
        "pid" => String.to_integer(System.pid()),
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "release" => to_string(Application.spec(:consigliere_daemon, :vsn) || "dev"),
        "home" => Path.expand(home),
        "uid" => File.stat!(lock_path(home)).uid,
        "lock" => "fcntl"
      })

    File.write!(owner_path(home), payload)
    File.chmod!(owner_path(home), 0o600)
    :ok
  end

  def lock_status(home \\ dir()) do
    expanded = Path.expand(home)
    path = lock_path(expanded)

    case :global.whereis_name({Consigliere.Home.Lock, expanded}) do
      pid when is_pid(pid) ->
        {:held, String.to_integer(System.pid())}

      :undefined ->
        case Consigliere.Home.Lock.NIF.inspect(path) do
          {:held, holder} when is_integer(holder) and holder > 0 -> {:held, holder}
          :absent -> :unowned
          :free -> if File.exists?(path), do: :stale, else: :unowned
          {:error, _} -> if File.exists?(path), do: :stale, else: :unowned
        end
    end
  end

  def record_error!(home \\ dir(), reason) do
    prepare_dir!(home)
    File.write!(last_error_path(home), reason)
  end

  def clear_error!(home \\ dir()) do
    File.rm(last_error_path(home))
    :ok
  end

  def last_error(home \\ dir()) do
    case File.read(last_error_path(home)) do
      {:ok, contents} -> contents
      {:error, :enoent} -> nil
    end
  end

  def forced_failure_reason do
    System.get_env("CS_FORCE_STARTUP_FAILURE")
  end

end
