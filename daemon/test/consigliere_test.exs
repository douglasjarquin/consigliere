defmodule ConsigliereTest do
  use ExUnit.Case
  doctest Consigliere

  test "greets the world" do
    assert Consigliere.hello() == :world
  end
end
