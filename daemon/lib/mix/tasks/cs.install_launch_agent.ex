defmodule Mix.Tasks.Cs.InstallLaunchAgent do
  use Mix.Task

  @shortdoc "Install a LaunchAgent that keeps csd running"

  @impl Mix.Task
  def run(_args) do
    home = Consigliere.Home.dir()
    Consigliere.Home.ensure_dir!(home)
    label = "ai.consigliere.csd"
    dest = Path.expand("~/Library/LaunchAgents/#{label}.plist")
    File.mkdir_p!(Path.dirname(dest))
    bin = System.find_executable("csd") || Path.expand("daemon/csd")
    File.write!(dest, plist(label, bin, home))
    IO.puts(dest)
  end

  defp plist(label, bin, home) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{bin}</string>
        <string>start</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>CS_HOME</key>
        <string>#{home}</string>
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
    </dict>
    </plist>
    """
  end
end
