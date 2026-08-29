defmodule Consigliere.Harness.Capture do
  @moduledoc """
  Bounded per-Attempt process output capture.

  Once the capture is full, the file contains a bounded head, a marker, and a
  bounded tail. The marker is part of the retained representation, so the
  file itself never exceeds the V0 capture limit.
  """

  alias Consigliere.Harness.Redaction
  alias Consigliere.V0.Limits

  @marker "\n[capture truncated]\n"
  @tail_bytes Limits.capture_bytes() - Limits.capture_head_bytes() - byte_size(@marker)

  def append(path, data) when is_binary(path) and is_binary(data) do
    with :ok <- Limits.validate_text(data),
         {:ok, current} <- read(path),
         {:ok, next} <- merge(current, Redaction.text(data)),
         :ok <- write(path, next) do
      :ok
    end
  rescue
    _ -> {:error, :capture_unavailable}
  end

  def append(_path, _data), do: {:error, :malformed}

  def read(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        if size > Limits.capture_bytes() do
          {:error, :capture_too_large}
        else
          case File.read(path) do
            {:ok, data} -> {:ok, data}
            {:error, _reason} -> {:error, :capture_unavailable}
          end
        end

      {:error, :enoent} ->
        {:ok, ""}

      {:error, _reason} ->
        {:error, :capture_unavailable}
    end
  end

  def read(_path), do: {:error, :malformed}

  def marker, do: @marker

  defp merge(current, data) when current == "", do: fit(data)

  defp merge(current, data) do
    if byte_size(current) + byte_size(data) <= Limits.capture_bytes() do
      {:ok, current <> data}
    else
      {head, tail} = retained_parts(current)
      {:ok, head <> @marker <> take_tail(tail <> data, @tail_bytes)}
    end
  end

  defp fit(data) do
    if byte_size(data) <= Limits.capture_bytes() do
      {:ok, data}
    else
      {:ok,
       binary_part(data, 0, Limits.capture_head_bytes()) <>
         @marker <> take_tail(data, @tail_bytes)}
    end
  end

  defp retained_parts(current) do
    case :binary.match(current, @marker) do
      {index, _length} ->
        {binary_part(current, 0, index),
         binary_part(
           current,
           index + byte_size(@marker),
           byte_size(current) - index - byte_size(@marker)
         )}

      :nomatch ->
        {binary_part(current, 0, min(byte_size(current), Limits.capture_head_bytes())), current}
    end
  end

  defp take_tail(value, max) when byte_size(value) <= max, do: value
  defp take_tail(value, max), do: binary_part(value, byte_size(value) - max, max)

  defp write(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, data, [:binary])
    File.chmod!(path, 0o600)
    :ok
  end
end
