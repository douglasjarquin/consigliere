defmodule Consigliere.CommandReceipts.Recovery do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    _ = Consigliere.CommandReceipts.reconcile_pending()
    {:ok, %{}}
  end
end
