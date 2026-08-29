defmodule Consigliere.API.Connection do
  @moduledoc false

  alias Consigliere.V0.Limits

  def child_spec({socket, bound}) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [socket, bound]},
      restart: :temporary
    }
  end

  def start_link(socket, bound) do
    Task.start_link(fn ->
      receive do
        :go -> loop(socket, bound)
      after
        5_000 -> :gen_tcp.close(socket)
      end
    end)
  end

  defp loop(socket, bound) do
    loop(socket, bound, 0, "")
  end

  defp loop(socket, bound, requests, buffer) do
    case recv_frame(socket, buffer) do
      {:ok, line, rest} ->
        if requests < Limits.requests_per_connection() do
          reply = Consigliere.API.Protocol.handle(line, bound)
          _ = :gen_tcp.send(socket, reply <> "\n")
          loop(socket, bound, requests + 1, rest)
        else
          send_terminal(socket, %{
            "v" => 1,
            "id" => nil,
            "ok" => false,
            "outcome" => "rejected",
            "error" => %{
              "code" => "request_limit",
              "reason" => "connection request limit exceeded"
            }
          })
        end

      {:error, :emsgsize} ->
        send_terminal(socket, %{
          "v" => 1,
          "id" => nil,
          "ok" => false,
          "outcome" => "rejected",
          "error" => %{"code" => "frame_too_large", "reason" => "frame exceeds V0 limit"}
        })

      {:error, :frame_too_large} ->
        send_terminal(socket, %{
          "v" => 1,
          "id" => nil,
          "ok" => false,
          "outcome" => "rejected",
          "error" => %{"code" => "frame_too_large", "reason" => "frame exceeds V0 limit"}
        })

      {:error, _reason} ->
        :gen_tcp.close(socket)
        :ok
    end
  end

  defp recv_frame(socket, buffer) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        line = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)

        if byte_size(line) > Limits.frame_bytes(),
          do: {:error, :frame_too_large},
          else: {:ok, line, rest}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, Limits.idle_timeout_ms()) do
          {:ok, chunk} ->
            next = buffer <> chunk

            if byte_size(next) > Limits.frame_bytes() + 1 do
              {:error, :frame_too_large}
            else
              recv_frame(socket, next)
            end

          {:error, :emsgsize} ->
            {:error, :emsgsize}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp send_terminal(socket, response) do
    _ = :gen_tcp.send(socket, JSON.encode!(response) <> "\n")
    :gen_tcp.close(socket)
  end
end
