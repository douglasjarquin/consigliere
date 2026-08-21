defmodule Consigliere.ProcessGroup.NIF do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:consigliere_daemon), ~c"cs_proc")
    :erlang.load_nif(path, 0)
  end

  def probe(_pgid), do: :erlang.nif_error(:nif_not_loaded)
end
