defmodule Consigliere.Harness do
  @moduledoc """
  Opens a harness session. Native resume is attempted once; an unknown
  session id falls back to exactly one fresh start (Phase 3 required test).
  """

  def open_session(adapter, spec) when is_atom(adapter) and is_map(spec) do
    case Map.get(spec, :native_session_id) do
      nil ->
        fresh(adapter, spec)

      id ->
        case adapter.resume(id, spec) do
          {:ok, ref} -> {:ok, ref, :resumed}
          {:error, _} -> fresh(adapter, spec)
        end
    end
  end

  defp fresh(adapter, spec) do
    case adapter.start(spec) do
      {:ok, ref} -> {:ok, ref, :fresh}
      other -> other
    end
  end
end
