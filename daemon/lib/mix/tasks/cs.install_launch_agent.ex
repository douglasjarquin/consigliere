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
    bin = System.find_executable("csd") || Path.expand("cli/csd")
    File.mkdir_p!(Consigliere.Home.logs_dir(home))
    File.write!(dest, plist(label, bin, home))
    IO.puts(dest)
  end

  defp plist(label, bin, home) do
    logs = Consigliere.Home.logs_dir(home)

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
        <string>foreground</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>CS_HOME</key>
        <string>#{home}</string>
      </dict>
      <key>WorkingDirectory</key>
      <string>#{home}</string>
      <key>StandardOutPath</key>
      <string>#{Path.join(logs, "csd.stdout.log")}</string>
      <key>StandardErrorPath</key>
      <string>#{Path.join(logs, "csd.stderr.log")}</string>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>ThrottleInterval</key>
      <integer>10</integer>
      <key>ProcessType</key>
      <string>Background</string>
    </dict>
    </plist>
    """
  end
end
