defmodule Consigliere.Questions do
  @moduledoc false

  alias Consigliere.Questions.Transitions

  defdelegate open(attrs, actor), to: Transitions
  defdelegate route(question_id, actor), to: Transitions
  defdelegate answer(question_id, actor, attrs), to: Transitions
  defdelegate withdraw(question_id, actor, reason), to: Transitions
  defdelegate expire(question_id, actor), to: Transitions
  defdelegate supersede(question_id, actor), to: Transitions
end
