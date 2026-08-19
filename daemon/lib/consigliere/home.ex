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
end
