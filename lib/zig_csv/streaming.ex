defmodule ZigCSV.Streaming do
  @moduledoc """
  Streaming CSV parser for processing large files with bounded memory.

  This module provides a streaming interface using the Zig NIF for batch
  parsing. It reads data in chunks and yields complete rows as they become
  available.

  ## Multi-Separator and Multi-Byte Support

  The streaming parser fully supports multiple separators and multi-byte
  separator/escape patterns. Configuration is passed as encoded binaries
  via the `:encoded_seps` and `:escape` options. When using a custom parser
  defined with `ZigCSV.define/2`, these are set automatically:

      ZigCSV.define(MyParser,
        separator: [",", "|"],
        escape: "\""
      )

      "data.csv"
      |> File.stream!()
      |> MyParser.parse_stream()
      |> Enum.each(&process_row/1)

  ## Memory Behavior

  The streaming parser maintains a small buffer for partial rows. Memory
  usage is bounded by:

    * `chunk_size` - bytes per IO read operation
    * `batch_size` - rows held before yielding
    * Maximum single row size in your data

  ## Usage

  For most use cases, use the high-level `parse_stream/2` function from
  your CSV module:

      alias ZigCSV.RFC4180, as: CSV

      "data.csv"
      |> File.stream!()
      |> CSV.parse_stream()
      |> Enum.each(&process_row/1)

  ## Direct Usage

  For more control, you can use this module directly:

      # Stream a file row by row
      ZigCSV.Streaming.stream_file("data.csv")
      |> Enum.each(&process_row/1)

      # Stream with custom chunk size
      ZigCSV.Streaming.stream_file("data.csv", chunk_size: 1024 * 1024)
      |> Enum.to_list()

      # Stream from an already-open device
      File.open!("data.csv", [:read, :binary], fn device ->
        ZigCSV.Streaming.stream_device(device)
        |> Enum.each(&IO.inspect/1)
      end)

  ## Encoding Support

  The streaming functions support character encoding conversion via the
  `:encoding` option. When a non-UTF8 encoding is specified, the stream
  is automatically converted to UTF-8 before parsing, with proper handling
  of multi-byte character boundaries across chunks.

  ## Implementation Notes

  The streaming parser:

    * Handles quoted fields that span multiple chunks correctly
    * Preserves quote state across chunk boundaries
    * Handles multi-byte character boundaries for non-UTF8 encodings
    * Supports multiple separators and multi-byte separator/escape patterns
    * Compacts internal buffer to prevent unbounded growth
    * Returns owned data (copies bytes) since input chunks are temporary

  """

  # ==========================================================================
  # Types
  # ==========================================================================

  @typedoc "A parsed row (list of field binaries)"
  @type row :: [binary()]

  @typedoc """
  Options for streaming functions.

    * `:chunk_size` - bytes per IO read operation. Defaults to `65536`.
    * `:batch_size` - maximum rows to yield per iteration. Defaults to `1000`.
    * `:encoded_seps` - length-prefixed binary encoding of separator patterns.
      Produced by `ZigCSV.encode_separators/1`. Defaults to comma (`<<1, 1, ?,>>`).
    * `:escape` - escape/quote binary. Defaults to `"\""`.
    * `:encoding` - character encoding of input data. Defaults to `:utf8`.
    * `:bom` - BOM bytes to strip when `:trim_bom` is `true`. Defaults to `""`.
    * `:trim_bom` - whether to strip BOM from the start of the stream. Defaults to `false`.
    * `:max_row_size` - maximum buffer size in bytes before raising. Prevents
      unbounded memory growth from unterminated quoted fields. Defaults to 16 MB.
  """
  @type stream_options :: [
          chunk_size: pos_integer(),
          batch_size: pos_integer(),
          encoded_seps: binary(),
          escape: binary(),
          encoding: ZigCSV.encoding(),
          bom: binary(),
          trim_bom: boolean(),
          max_row_size: pos_integer()
        ]

  # ==========================================================================
  # Constants
  # ==========================================================================

  @default_chunk_size 64 * 1024
  @default_batch_size 1000
  @default_encoded_seps <<1, 1, ?,>>
  @default_escape "\""
  @default_max_row_size 16 * 1024 * 1024
  # Minimum buffer size before calling NIF for enumerable streaming.
  # Prevents per-line NIF calls when input is line-based (e.g., File.stream!()).
  @min_buffer_size 64 * 1024

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Create a stream that reads a CSV file in chunks.

  Opens the file, creates a streaming parser, and returns a `Stream` that
  yields rows as they are parsed. The file is automatically closed when
  the stream is consumed or halted.

  ## Options

    * `:chunk_size` - Bytes to read per IO operation. Defaults to `65536` (64 KB).
      Larger chunks mean fewer IO operations but more memory per read.

    * `:batch_size` - Maximum rows to yield per stream iteration. Defaults to `1000`.
      Larger batches are more efficient but delay processing of early rows.

  ## Returns

  A `Stream` that yields rows. Each row is a list of field binaries.

  ## Examples

      # Process a file row by row
      ZigCSV.Streaming.stream_file("data.csv")
      |> Enum.each(fn row ->
        IO.inspect(row)
      end)

      # Take first 5 rows
      ZigCSV.Streaming.stream_file("data.csv")
      |> Enum.take(5)

      # With custom options
      ZigCSV.Streaming.stream_file("huge.csv",
        chunk_size: 1024 * 1024,  # 1 MB chunks
        batch_size: 5000
      )
      |> Stream.map(&process_row/1)
      |> Stream.run()

  """
  @spec stream_file(Path.t(), stream_options()) :: Enumerable.t()
  def stream_file(path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    encoded_seps = Keyword.get(opts, :encoded_seps, @default_encoded_seps)
    escape = Keyword.get(opts, :escape, @default_escape)
    max_row_size = Keyword.get(opts, :max_row_size, @default_max_row_size)

    Stream.resource(
      fn ->
        init_file_stream(path, chunk_size, batch_size, encoded_seps, escape, max_row_size)
      end,
      &next_rows_file/1,
      &cleanup_file_stream/1
    )
  end

  @doc """
  Create a stream from an enumerable (like `File.stream!/1`).

  This is used internally by `parse_stream/2` to handle line-oriented or
  chunk-oriented input from any enumerable source.

  ## Options

    * `:chunk_size` - Not used for enumerables (chunks come from source).

    * `:batch_size` - Maximum rows to yield per iteration. Defaults to `1000`.

    * `:encoding` - Character encoding of input. Defaults to `:utf8`.

    * `:bom` - BOM to strip if `:trim_bom` is true. Defaults to `""`.

    * `:trim_bom` - Whether to strip BOM from start. Defaults to `false`.

  ## Examples

      # Parse from a list of chunks
      ["name,age\\n", "john,27\\n", "jane,30\\n"]
      |> ZigCSV.Streaming.stream_enumerable()
      |> Enum.to_list()
      #=> [["name", "age"], ["john", "27"], ["jane", "30"]]

      # Parse from File.stream!
      File.stream!("data.csv")
      |> ZigCSV.Streaming.stream_enumerable()
      |> Enum.each(&process/1)

  """
  @spec stream_enumerable(Enumerable.t(), stream_options()) :: Enumerable.t()
  def stream_enumerable(enumerable, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    encoded_seps = Keyword.get(opts, :encoded_seps, @default_encoded_seps)
    escape = Keyword.get(opts, :escape, @default_escape)
    encoding = Keyword.get(opts, :encoding, :utf8)
    bom = Keyword.get(opts, :bom, "")
    trim_bom = Keyword.get(opts, :trim_bom, false)

    # If encoding is not UTF-8, convert stream to UTF-8 first
    converted_enumerable =
      if encoding == :utf8 do
        if trim_bom and bom != "" do
          strip_bom_stream(enumerable, bom)
        else
          enumerable
        end
      else
        enumerable
        |> maybe_strip_bom_stream(trim_bom, bom)
        |> convert_stream_to_utf8(encoding)
      end

    max_row_size = Keyword.get(opts, :max_row_size, @default_max_row_size)

    Stream.resource(
      fn ->
        init_enum_stream(converted_enumerable, batch_size, encoded_seps, escape, max_row_size)
      end,
      &next_rows_enum/1,
      fn _state -> :ok end
    )
  end

  # Strip BOM from first chunk of stream if present
  defp strip_bom_stream(enumerable, bom) do
    bom_size = byte_size(bom)

    Stream.transform(enumerable, true, fn
      chunk, true ->
        # First chunk - check and strip BOM
        if binary_part(chunk, 0, min(byte_size(chunk), bom_size)) == bom do
          {[binary_part(chunk, bom_size, byte_size(chunk) - bom_size)], false}
        else
          {[chunk], false}
        end

      chunk, false ->
        {[chunk], false}
    end)
  end

  defp maybe_strip_bom_stream(enumerable, true, bom) when bom != "",
    do: strip_bom_stream(enumerable, bom)

  defp maybe_strip_bom_stream(enumerable, _, _), do: enumerable

  # Convert stream from source encoding to UTF-8, handling multi-byte boundaries
  defp convert_stream_to_utf8(stream, encoding) do
    Stream.transform(stream, <<>>, fn chunk, acc ->
      input = acc <> chunk

      case :unicode.characters_to_binary(input, encoding, :utf8) do
        binary when is_binary(binary) ->
          # Full conversion succeeded
          {[binary], <<>>}

        {:incomplete, converted, rest} ->
          # Partial conversion - rest contains incomplete multi-byte sequence
          {[converted], rest}

        {:error, converted, rest} ->
          raise ZigCSV.ParseError,
            message:
              "Invalid #{inspect(encoding)} sequence at byte #{byte_size(converted)}: " <>
                "#{inspect(binary_part(rest, 0, min(byte_size(rest), 10)))}"
      end
    end)
  end

  @doc """
  Stream from an already-open IO device.

  Useful when you want more control over file opening/closing, or when
  reading from a socket or other IO device.

  Note: This function does NOT close the device when done. The caller
  is responsible for closing it.

  ## Options

    * `:chunk_size` - Bytes to read per IO operation. Defaults to `65536`.

    * `:batch_size` - Maximum rows to yield per iteration. Defaults to `1000`.

  ## Examples

      File.open!("data.csv", [:read, :binary], fn device ->
        ZigCSV.Streaming.stream_device(device)
        |> Enum.each(&IO.inspect/1)
      end)

  """
  @spec stream_device(IO.device(), stream_options()) :: Enumerable.t()
  def stream_device(device, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    encoded_seps = Keyword.get(opts, :encoded_seps, @default_encoded_seps)
    escape = Keyword.get(opts, :escape, @default_escape)
    max_row_size = Keyword.get(opts, :max_row_size, @default_max_row_size)

    Stream.resource(
      fn ->
        init_device_stream(device, chunk_size, batch_size, encoded_seps, escape, max_row_size)
      end,
      &next_rows_device/1,
      fn _state -> :ok end
    )
  end

  @doc """
  Parse binary chunks and return all rows.

  This is mainly useful for testing the streaming parser with in-memory data.
  For actual streaming use cases, use `stream_file/2` or `stream_enumerable/2`.

  ## Options

    * `:encoded_seps` - Encoded separators binary. Defaults to comma.
    * `:escape` - Escape binary. Defaults to `"\""`.

  ## Examples

      ZigCSV.Streaming.parse_chunks(["a,b\\n1,", "2\\n3,4\\n"])
      #=> [["a", "b"], ["1", "2"], ["3", "4"]]

  """
  @spec parse_chunks([binary()], keyword()) :: [row()]
  def parse_chunks(chunks, opts \\ []) when is_list(chunks) do
    encoded_seps = Keyword.get(opts, :encoded_seps, @default_encoded_seps)
    escape = Keyword.get(opts, :escape, @default_escape)
    max_row_size = Keyword.get(opts, :max_row_size, @default_max_row_size)

    # Use reverse list accumulation to avoid O(n^2) concatenation
    {rows_reversed, leftover} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {acc_rows, buffer} ->
        check_buffer_size!(buffer, max_row_size)
        data = buffer <> chunk

        # Single NIF call does both boundary detection AND parsing
        {new_rows, consumed} = parse_chunk_nif(data, encoded_seps, escape)

        if consumed > 0 and consumed <= byte_size(data) do
          remaining = binary_part(data, consumed, byte_size(data) - consumed)
          # Prepend reversed new_rows to accumulator
          {Enum.reverse(new_rows) ++ acc_rows, remaining}
        else
          {acc_rows, data}
        end
      end)

    # Parse any remaining data (final incomplete row)
    final_rows =
      if byte_size(leftover) > 0 do
        ZigCSV.Native.parse_fast(leftover, encoded_seps, escape)
      else
        []
      end

    # Reverse to get correct order, then append final rows
    Enum.reverse(rows_reversed) ++ final_rows
  end

  # ==========================================================================
  # File Streaming (Private)
  # ==========================================================================

  defp init_file_stream(path, chunk_size, batch_size, encoded_seps, escape, max_row_size) do
    device = File.open!(path, [:read, :binary, :raw])
    {:file, device, "", [], encoded_seps, escape, chunk_size, batch_size, max_row_size}
  end

  defp next_rows_file(
         {:file, device, buffer, rows, encoded_seps, escape, chunk_size, batch_size, max_row_size}
       ) do
    if length(rows) >= batch_size do
      {to_emit, rest} = Enum.split(rows, batch_size)

      {to_emit,
       {:file, device, buffer, rest, encoded_seps, escape, chunk_size, batch_size, max_row_size}}
    else
      read_and_process_file(
        device,
        buffer,
        rows,
        encoded_seps,
        escape,
        chunk_size,
        batch_size,
        max_row_size
      )
    end
  end

  defp next_rows_file({:done, rows}) do
    if rows == [] do
      {:halt, {:done, []}}
    else
      {rows, {:done, []}}
    end
  end

  defp read_and_process_file(
         device,
         buffer,
         rows,
         encoded_seps,
         escape,
         chunk_size,
         batch_size,
         max_row_size
       ) do
    case IO.binread(device, chunk_size) do
      :eof ->
        File.close(device)
        # Parse remaining buffer
        final_rows =
          if byte_size(buffer) > 0 do
            parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
            rows ++ parsed
          else
            rows
          end

        if final_rows == [] do
          {:halt, {:done, []}}
        else
          {final_rows, {:done, []}}
        end

      {:error, reason} ->
        File.close(device)
        raise "Error reading CSV file: #{inspect(reason)}"

      chunk when is_binary(chunk) ->
        check_buffer_size!(buffer, max_row_size)
        data = buffer <> chunk

        %{:"0" => parsed, :"1" => consumed} =
          ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

        {new_rows, remaining} =
          if consumed > 0 and consumed <= byte_size(data) do
            {rows ++ parsed, binary_part(data, consumed, byte_size(data) - consumed)}
          else
            {rows, data}
          end

        if length(new_rows) >= batch_size do
          {to_emit, rest} = Enum.split(new_rows, batch_size)

          {to_emit,
           {:file, device, remaining, rest, encoded_seps, escape, chunk_size, batch_size,
            max_row_size}}
        else
          next_rows_file(
            {:file, device, remaining, new_rows, encoded_seps, escape, chunk_size, batch_size,
             max_row_size}
          )
        end
    end
  end

  defp cleanup_file_stream({:file, device, _, _, _, _, _, _, _}) do
    File.close(device)
  end

  defp cleanup_file_stream({:done, _}) do
    :ok
  end

  # ==========================================================================
  # Enumerable Streaming (Private)
  # ==========================================================================

  defp init_enum_stream(enumerable, batch_size, encoded_seps, escape, max_row_size) do
    iterator =
      Enumerable.reduce(enumerable, {:cont, nil}, fn item, _acc -> {:suspend, item} end)

    # State: {iterator, buffer_chunks (iodata, reversed), buffer_size, rows, row_count, config...}
    {:enum, iterator, [], 0, [], 0, encoded_seps, escape, batch_size, max_row_size}
  end

  defp next_rows_enum(
         {:enum, {:suspended, chunk, continuation}, buf_chunks, buf_size, rows, row_count,
          encoded_seps, escape, batch_size, max_row_size}
       ) do
    chunk_binary = if is_binary(chunk), do: chunk, else: to_string(chunk)
    new_buf_chunks = [chunk_binary | buf_chunks]
    new_buf_size = buf_size + byte_size(chunk_binary)

    # Buffer small chunks to avoid per-line NIF calls (e.g., File.stream!())
    if new_buf_size < @min_buffer_size do
      next_iterator = continuation.({:cont, nil})

      next_rows_enum(
        {:enum, next_iterator, new_buf_chunks, new_buf_size, rows, row_count, encoded_seps,
         escape, batch_size, max_row_size}
      )
    else
      data = IO.iodata_to_binary(Enum.reverse(new_buf_chunks))
      check_buffer_size!(data, max_row_size)

      {parsed, consumed} = parse_chunk_nif(data, encoded_seps, escape)

      parsed_count = length(parsed)

      {new_rows, new_row_count, remaining} =
        if consumed > 0 and consumed <= byte_size(data) do
          {rows ++ parsed, row_count + parsed_count,
           binary_part(data, consumed, byte_size(data) - consumed)}
        else
          {rows, row_count, data}
        end

      next_iterator = continuation.({:cont, nil})

      if new_row_count >= batch_size do
        {to_emit, rest} = Enum.split(new_rows, batch_size)

        {to_emit,
         {:enum, next_iterator, [remaining], byte_size(remaining), rest,
          new_row_count - batch_size, encoded_seps, escape, batch_size, max_row_size}}
      else
        next_rows_enum(
          {:enum, next_iterator, [remaining], byte_size(remaining), new_rows, new_row_count,
           encoded_seps, escape, batch_size, max_row_size}
        )
      end
    end
  end

  defp next_rows_enum(
         {:enum, {:done, _}, buf_chunks, _buf_size, rows, _row_count, encoded_seps, escape,
          batch_size, max_row_size}
       ) do
    # Flush remaining buffer
    buffer = IO.iodata_to_binary(Enum.reverse(buf_chunks))
    check_buffer_size!(buffer, max_row_size)

    final_rows =
      if byte_size(buffer) > 0 do
        parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
        rows ++ parsed
      else
        rows
      end

    if final_rows == [] do
      {:halt, {:enum, {:done, nil}, [], 0, [], 0, encoded_seps, escape, batch_size, max_row_size}}
    else
      {final_rows,
       {:enum, {:done, nil}, [], 0, [], 0, encoded_seps, escape, batch_size, max_row_size}}
    end
  end

  defp next_rows_enum(
         {:enum, {:halted, _}, buf_chunks, _buf_size, rows, _row_count, encoded_seps, escape,
          batch_size, max_row_size}
       ) do
    # Stream was halted - finalize remaining
    buffer = IO.iodata_to_binary(Enum.reverse(buf_chunks))

    final_rows =
      if byte_size(buffer) > 0 do
        parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
        rows ++ parsed
      else
        rows
      end

    if final_rows == [] do
      {:halt,
       {:enum, {:halted, nil}, [], 0, [], 0, encoded_seps, escape, batch_size, max_row_size}}
    else
      {final_rows,
       {:enum, {:halted, nil}, [], 0, [], 0, encoded_seps, escape, batch_size, max_row_size}}
    end
  end

  # ==========================================================================
  # Device Streaming (Private)
  # ==========================================================================

  defp init_device_stream(device, chunk_size, batch_size, encoded_seps, escape, max_row_size) do
    {:device, device, "", [], encoded_seps, escape, chunk_size, batch_size, max_row_size}
  end

  defp next_rows_device(
         {:device, device, buffer, rows, encoded_seps, escape, chunk_size, batch_size,
          max_row_size}
       ) do
    if length(rows) >= batch_size do
      {to_emit, rest} = Enum.split(rows, batch_size)

      {to_emit,
       {:device, device, buffer, rest, encoded_seps, escape, chunk_size, batch_size, max_row_size}}
    else
      read_and_process_device(
        device,
        buffer,
        rows,
        encoded_seps,
        escape,
        chunk_size,
        batch_size,
        max_row_size
      )
    end
  end

  defp next_rows_device({:device_done, rows}) do
    if rows == [] do
      {:halt, {:device_done, []}}
    else
      {rows, {:device_done, []}}
    end
  end

  defp read_and_process_device(
         device,
         buffer,
         rows,
         encoded_seps,
         escape,
         chunk_size,
         batch_size,
         max_row_size
       ) do
    case IO.binread(device, chunk_size) do
      :eof ->
        final_rows =
          if byte_size(buffer) > 0 do
            parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
            rows ++ parsed
          else
            rows
          end

        if final_rows == [] do
          {:halt, {:device_done, []}}
        else
          {final_rows, {:device_done, []}}
        end

      {:error, reason} ->
        raise "Error reading from device: #{inspect(reason)}"

      chunk when is_binary(chunk) ->
        check_buffer_size!(buffer, max_row_size)
        data = buffer <> chunk

        %{:"0" => parsed, :"1" => consumed} =
          ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

        {new_rows, remaining} =
          if consumed > 0 and consumed <= byte_size(data) do
            {rows ++ parsed, binary_part(data, consumed, byte_size(data) - consumed)}
          else
            {rows, data}
          end

        if length(new_rows) >= batch_size do
          {to_emit, rest} = Enum.split(new_rows, batch_size)

          {to_emit,
           {:device, device, remaining, rest, encoded_seps, escape, chunk_size, batch_size,
            max_row_size}}
        else
          next_rows_device(
            {:device, device, remaining, new_rows, encoded_seps, escape, chunk_size, batch_size,
             max_row_size}
          )
        end
    end
  end

  # ==========================================================================
  # NIF Wrapper
  # ==========================================================================

  # Zigler generates an incorrect typespec (map instead of tuple) for Zig
  # struct returns. The NIF actually returns {rows, consumed} at runtime.
  # Using :erlang.apply/3 prevents Dialyzer from tracing through to
  # zigler's incorrect spec.
  @spec parse_chunk_nif(binary(), binary(), binary()) ::
          {[ZigCSV.Native.row()], non_neg_integer()}
  defp parse_chunk_nif(data, encoded_seps, escape) do
    :erlang.apply(ZigCSV.Native, :parse_chunk_encoded, [data, encoded_seps, escape])
  end

  # ==========================================================================
  # Buffer Size Guard
  # ==========================================================================

  defp check_buffer_size!(buffer, max_row_size) when is_binary(buffer) do
    if byte_size(buffer) > max_row_size do
      raise ZigCSV.ParseError,
        message:
          "streaming buffer exceeded max_row_size (#{max_row_size} bytes). " <>
            "This usually indicates an unterminated quoted field. " <>
            "Increase :max_row_size if your data legitimately contains very large rows."
    end
  end
end
