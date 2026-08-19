defmodule Mix.Tasks.Cs.Doctor do
  use Mix.Task

  @shortdoc "Diagnose the consigliere daemon's home-directory state"

  @impl Mix.Task
  def run(_args) do
    Consigliere.CLI.doctor()
  end
end
