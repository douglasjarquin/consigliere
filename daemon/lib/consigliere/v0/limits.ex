defmodule Consigliere.V0.Limits do
  @moduledoc """
  The fixed resource and protocol limits for the Local V0 surface.

  JSON frames are scanned before decoding so a hostile peer cannot use a
  deeply nested or broad value to make the decoder allocate without a bound.
  Decoded values are checked again at the boundary that owns them.
  """

  @frame_bytes 1_048_576
  @json_depth 64
  @collection_items 256
  @string_bytes 65_536
  @requests_per_connection 1_024
  @idle_timeout_ms 300_000
  @capture_bytes 8_388_608
  @capture_head_bytes 4_194_304
  @capture_tail_bytes 4_194_304
  @semantic_payload_bytes 65_536
  @final_text_bytes 4_096
  @usage_rows 4_096
  @usage_bytes 1_048_576

  def frame_bytes, do: @frame_bytes
  def json_depth, do: @json_depth
  def collection_items, do: @collection_items
  def string_bytes, do: @string_bytes
  def requests_per_connection, do: @requests_per_connection
  def idle_timeout_ms, do: @idle_timeout_ms
  def capture_bytes, do: @capture_bytes
  def capture_head_bytes, do: @capture_head_bytes
  def capture_tail_bytes, do: @capture_tail_bytes
  def semantic_payload_bytes, do: @semantic_payload_bytes
  def final_text_bytes, do: @final_text_bytes
  def usage_rows, do: @usage_rows
  def usage_bytes, do: @usage_bytes

  def validate_json_frame(value) when is_binary(value) do
    cond do
      byte_size(value) > @frame_bytes ->
        {:error, :frame_too_large}

      not String.valid?(value) ->
        {:error, :invalid_utf8}

      true ->
        case scan(value, 0, byte_size(value), []) do
          :ok ->
            case JSON.decode(String.trim(value)) do
              {:ok, _decoded} -> {:ok, String.trim(value)}
              _ -> {:error, :malformed_json}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  def validate_json_frame(_value), do: {:error, :malformed_json}

  def validate_value(value), do: validate_value(value, 0)

  def encoded_size(value) do
    with :ok <- validate_value(value) do
      try do
        {:ok, byte_size(JSON.encode!(value))}
      rescue
        _ -> {:error, :malformed_value}
      end
    end
  end

  def validate_text(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      unsafe_text?(value) -> {:error, :unsafe_control_sequence}
      true -> :ok
    end
  end

  def validate_text(_value), do: {:error, :invalid_utf8}

  defp validate_value(_value, depth) when depth > @json_depth,
    do: {:error, :json_depth_exceeded}

  defp validate_value(value, depth) when is_map(value) do
    if map_size(value) > @collection_items do
      {:error, :collection_too_large}
    else
      Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
        with :ok <- validate_key(key),
             :ok <- validate_value(nested, depth + 1) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_value(value, depth) when is_list(value) do
    if length(value) > @collection_items do
      {:error, :collection_too_large}
    else
      Enum.reduce_while(value, :ok, fn nested, :ok ->
        case validate_value(nested, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_value(value, _depth) when is_binary(value) do
    cond do
      byte_size(value) > @string_bytes -> {:error, :string_too_large}
      not String.valid?(value) -> {:error, :invalid_utf8}
      unsafe_text?(value) -> {:error, :unsafe_control_sequence}
      true -> :ok
    end
  end

  defp validate_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_value(_value, _depth), do: {:error, :unsupported_value}

  defp validate_key(key) when is_binary(key), do: validate_value(key, @json_depth)
  defp validate_key(key) when is_atom(key), do: validate_key(Atom.to_string(key))
  defp validate_key(_key), do: {:error, :invalid_key}

  defp unsafe_text?(value) do
    String.contains?(value, <<0x1B>>) or String.contains?(value, <<0x9D>>)
  end

  defp scan(_value, index, size, _stack) when index >= size, do: :ok

  defp scan(value, index, size, stack) do
    case :binary.at(value, index) do
      byte
      when byte in [
             0,
             1,
             2,
             3,
             4,
             5,
             6,
             7,
             8,
             11,
             12,
             14,
             15,
             16,
             17,
             18,
             19,
             20,
             21,
             22,
             23,
             24,
             25,
             26,
             27,
             28,
             29,
             30,
             31
           ] ->
        if byte == 27, do: {:error, :unsafe_control_sequence}, else: {:error, :malformed_json}

      0x9D ->
        {:error, :unsafe_control_sequence}

      byte when byte in [9, 10, 13, 32] ->
        scan(value, index + 1, size, stack)

      34 ->
        case scan_string(value, index + 1, size, 0) do
          {:ok, next} -> scan(value, next, size, stack)
          {:error, _reason} = error -> error
        end

      123 ->
        push_container(value, index, size, stack, :object)

      91 ->
        push_container(value, index, size, stack, :array)

      125 ->
        close_container(value, index, size, stack, :object)

      93 ->
        close_container(value, index, size, stack, :array)

      44 ->
        increment_collection(value, index, size, stack)

      _byte ->
        scan(value, index + 1, size, stack)
    end
  end

  defp push_container(_value, _index, _size, stack, _kind)
       when length(stack) >= @json_depth,
       do: {:error, :json_depth_exceeded}

  defp push_container(value, index, size, stack, kind),
    do: scan(value, index + 1, size, [{kind, 0} | stack])

  defp close_container(_value, _index, _size, [], _kind),
    do: {:error, :malformed_json}

  defp close_container(value, index, size, [{kind, _commas} | rest], kind),
    do: scan(value, index + 1, size, rest)

  defp close_container(_value, _index, _size, _stack, _kind),
    do: {:error, :malformed_json}

  defp increment_collection(_value, _index, _size, []),
    do: {:error, :malformed_json}

  defp increment_collection(_value, _index, _size, [{_kind, commas} | _rest])
       when commas >= @collection_items - 1,
       do: {:error, :collection_too_large}

  defp increment_collection(value, index, size, [{kind, commas} | rest]),
    do: scan(value, index + 1, size, [{kind, commas + 1} | rest])

  defp scan_string(_value, _index, _size, count) when count > @string_bytes,
    do: {:error, :string_too_large}

  defp scan_string(_value, index, size, _count) when index >= size,
    do: {:error, :malformed_json}

  defp scan_string(value, index, size, count) do
    case :binary.at(value, index) do
      34 -> {:ok, index + 1}
      92 -> scan_escape(value, index, size, count)
      byte when byte == 27 or byte == 0x9D -> {:error, :unsafe_control_sequence}
      byte when byte < 32 -> {:error, :malformed_json}
      _byte -> scan_string(value, index + 1, size, count + 1)
    end
  end

  defp scan_escape(_value, index, size, _count) when index + 1 >= size,
    do: {:error, :malformed_json}

  defp scan_escape(value, index, size, count) do
    escaped = :binary.at(value, index + 1)

    cond do
      escaped == 117 and index + 5 < size ->
        codepoint = binary_part(value, index + 2, 4)

        if String.downcase(codepoint) == "001b" do
          {:error, :unsafe_control_sequence}
        else
          scan_string(value, index + 6, size, count + 6)
        end

      escaped in [34, 92, 47, 98, 102, 110, 114, 116] ->
        scan_string(value, index + 2, size, count + 2)

      true ->
        {:error, :malformed_json}
    end
  end
end
