defmodule Consigliere.Adapters do
  @moduledoc """
  Production-default adapter selection. Test env may override these;
  production never silently falls back to a Fake.
  """

  def harness do
    Application.get_env(:consigliere_daemon, :harness_adapter, Consigliere.Harness.Codex)
  end

  def made do
    Application.get_env(:consigliere_daemon, :made_adapter, Consigliere.Made.Process)
  end

  def github do
    Application.get_env(:consigliere_daemon, :github_adapter, Consigliere.GitHub.Gh)
  end
end
