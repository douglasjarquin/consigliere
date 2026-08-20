defmodule Consigliere.NotificationDispatcher do
  @moduledoc """
  Best-effort notification delivery via the outbox. A crash here cannot
  lose a Question: the Question row already exists before any notify.
  """
  use GenServer

  alias Consigliere.Home
  alias Consigliere.OutboxDispatcher

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  def deliver(item) do
    home = Home.dir()
    Home.ensure_dir!(home)
    line = JSON.encode!(item.payload || %{}) <> "\n"
    File.write!(Path.join(home, "notifications.log"), line, [:append])
    :ok
  end

  @impl true
  def init(_opts) do
    _ = OutboxDispatcher.put_handler("notification", &deliver/1)
    {:ok, %{}}
  end
end
