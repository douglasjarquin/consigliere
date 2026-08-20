defmodule Consigliere.Home.Lock.NIF do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:consigliere_daemon), ~c"cs_home_lock")
    :erlang.load_nif(path, 0)
  end

  def acquire(_path), do: :erlang.nif_error(:nif_not_loaded)
  def release(_ref), do: :erlang.nif_error(:nif_not_loaded)
  def inspect(_path), do: :erlang.nif_error(:nif_not_loaded)
end
