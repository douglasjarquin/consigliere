defmodule Consigliere.Home do
  @moduledoc false

  def dir do
    System.get_env("CS_HOME") || Path.expand("~/.consigliere")
  end

  def ensure_dir!(home \\ dir()) do
    File.mkdir_p!(home)
    home
  end

  def boss_socket_path(home \\ dir()) do
    Path.join(home, "boss.sock")
  end

  def last_error_path(home \\ dir()) do
    Path.join(home, "last_error.log")
  end

  def socket_status(home \\ dir()) do
    socket_path = boss_socket_path(home)

    if File.exists?(socket_path) do
      case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 200) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :live

        {:error, _not_live} ->
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
