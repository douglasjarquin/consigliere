defmodule Consigliere.API.Auth do
  @moduledoc false

  alias Consigliere.Actor
  alias Consigliere.Home

  def identify(req, :unbound), do: from_json(req)

  def identify(req, :privileged) do
    if secret_ok?(req) do
      Actor.boss()
    else
      {:error, "privileged auth failed"}
    end
  end

  def identify(req, bound) when bound in [:capability, :api] do
    token = req["capability"] || req["secret"] || get_in(req, ["actor", "capability"])

    case Consigliere.Capabilities.authenticate(token) do
      {:ok, cap} ->
        if declared_mismatch?(req, cap) do
          {:error, "capability actor mismatch"}
        else
          allow = get_in(cap.ops, ["allow"]) || []
          Actor.attempt(cap.attempt_id, cap.fencing_token, allow)
        end

      {:error, _} ->
        if advisory_ok?(token) do
          Actor.model_advisory()
        else
          {:error, "api auth failed"}
        end
    end
  end

  defp declared_mismatch?(req, cap) do
    actor = req["actor"] || %{}

    cond do
      actor["principal"] in ["boss", "daemon", "model_advisory"] -> true
      is_binary(actor["attempt_id"]) and actor["attempt_id"] != cap.attempt_id -> true
      true -> false
    end
  end

  def from_json(%{"actor" => %{"principal" => principal} = raw}) when is_binary(principal) do
    %Actor{
      principal: principal,
      attempt_id: raw["attempt_id"],
      fencing_token: raw["fencing_token"],
      channel: raw["channel"] || default_channel(principal)
    }
  end

  def from_json(_), do: {:error, "missing actor.principal"}

  defp default_channel("boss"), do: "privileged"
  defp default_channel("attempt"), do: "capability"
  defp default_channel("daemon"), do: "internal"
  defp default_channel(_), do: "advisory"

  defp secret_ok?(req) do
    given = req["secret"] || get_in(req, ["actor", "secret"])
    expected = Home.ensure_boss_secret!()
    is_binary(given) and given != "" and secure_eq?(given, expected)
  end

  defp advisory_ok?(token) when is_binary(token) and token != "" do
    expected = Home.ensure_advisory_secret!()
    secure_eq?(token, expected)
  end

  defp advisory_ok?(_), do: false

  defp secure_eq?(a, b) do
    :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
  end
end
