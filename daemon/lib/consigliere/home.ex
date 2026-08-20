defmodule Consigliere.Home do
  @moduledoc false

  def dir do
    System.get_env("CS_HOME") || Path.expand("~/.consigliere")
  end

  def ensure_dir!(home \\ dir()) do
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    File.mkdir_p!(credentials_dir(home))
    File.mkdir_p!(trusted_projects_dir(home))
    File.mkdir_p!(workspaces_dir(home))
    File.mkdir_p!(runtime_attempts_dir(home))
    File.mkdir_p!(evidence_dir(home))
    File.mkdir_p!(logs_dir(home))
    File.chmod!(credentials_dir(home), 0o700)
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

  def record_error!(home \\ dir(), reason) do
    ensure_dir!(home)
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
