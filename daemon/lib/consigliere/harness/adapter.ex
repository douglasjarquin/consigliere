defmodule Consigliere.Harness.Adapter do
  @moduledoc """
  The seven-function adapter contract in docs/protocols/harness-adapter.md.
  The daemon never branches on harness name outside this boundary.
  """

  @type spec :: map()
  @type session_ref :: map()

  @callback capabilities() :: map()
  @callback start(spec()) :: {:ok, session_ref()} | {:error, term()}
  @callback resume(String.t(), spec()) :: {:ok, session_ref()} | {:error, term()}
  @callback send(session_ref(), term()) :: :ok | {:error, term()}
  @callback interrupt(session_ref()) :: :ok | {:error, term()}
  @callback cancel(session_ref()) :: :ok | {:error, term()}
  @callback snapshot(session_ref()) :: map()
end
