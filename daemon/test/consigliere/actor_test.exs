defmodule Consigliere.ActorTest do
  use ExUnit.Case, async: true

  alias Consigliere.Actor

  test "system actor is the daemon principal on the internal channel" do
    actor = Actor.system()
    assert actor.principal == "daemon"
    assert actor.channel == "internal"
  end

  test "boss actor is the boss principal on the privileged channel" do
    actor = Actor.boss()
    assert actor.principal == "boss"
    assert actor.channel == "privileged"
  end

  test "attempt actor carries id and fencing token" do
    actor = Actor.attempt("att-1", "fence-1")
    assert actor.principal == "attempt"
    assert actor.attempt_id == "att-1"
    assert actor.fencing_token == "fence-1"
    assert actor.channel == "capability"
  end
end
