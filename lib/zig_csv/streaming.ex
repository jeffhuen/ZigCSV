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
  """
  @type stream_options :: [
          chunk_size: pos_integer(),
          batch_size: pos_integer(),
          encoded_seps: binary(),
          escape: binary(),
          encoding: ZigCSV.encoding(),
          bom: binary(),
          trim_bom: boolean()
        ]

  # ==========================================================================
  # Constants
  # ==========================================================================

  @default_chunk_size 64 * 1024
  @default_batch_size 1000
  @default_encoded_seps <<1, 1, ?,>>
  @default_escape "\""

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

    Stream.resource(
      fn -> init_file_stream(path, chunk_size, batch_size, encoded_seps, escape) end,
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

    Stream.resource(
      fn -> init_enum_stream(converted_enumerable, batch_size, encoded_seps, escape) end,
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

    Stream.resource(
      fn -> init_device_stream(device, chunk_size, batch_size, encoded_seps, escape) end,
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

    # Use reverse list accumulation to avoid O(n^2) concatenation
    {rows_reversed, leftover} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {acc_rows, buffer} ->
        data = buffer <> chunk

        # Single NIF call does both boundary detection AND parsing
        {new_rows, consumed} = ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

        if consumed > 0 do
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

  defp init_file_stream(path, chunk_size, batch_size, encoded_seps, escape) do
    device = File.open!(path, [:read, :binary, :raw])
    {:file, device, "", [], encoded_seps, escape, chunk_size, batch_size}
  end

  defp next_rows_file({:file, device, buffer, rows, encoded_seps, escape, chunk_size, batch_size}) do
    if length(rows) >= batch_size do
      {to_emit, rest} = Enum.split(rows, batch_size)
      {to_emit, {:file, device, buffer, rest, encoded_seps, escape, chunk_size, batch_size}}
    else
      read_and_process_file(device, buffer, rows, encoded_seps, escape, chunk_size, batch_size)
    end
  end

  defp next_rows_file({:done, rows}) do
    if rows == [] do
      {:halt, {:done, []}}
    else
      {rows, {:done, []}}
    end
  end

  defp read_and_process_file(device, buffer, rows, encoded_seps, escape, chunk_size, batch_size) do
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
        data = buffer <> chunk

        {parsed, consumed} = ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

        {new_rows, remaining} =
          if consumed > 0 do
            {rows ++ parsed, binary_part(data, consumed, byte_size(data) - consumed)}
          else
            {rows, data}
          end

        if length(new_rows) >= batch_size do
          {to_emit, rest} = Enum.split(new_rows, batch_size)
          {to_emit, {:file, device, remaining, rest, encoded_seps, escape, chunk_size, batch_size}}
        else
          next_rows_file(
            {:file, device, remaining, new_rows, encoded_seps, escape, chunk_size, batch_size}
          )
        end
    end
  end

  defp cleanup_file_stream({:file, device, _, _, _, _, _, _}) do
    File.close(device)
  end

  defp cleanup_file_stream({:done, _}) do
    :ok
  end

  # ==========================================================================
  # Enumerable Streaming (Private)
  # ==========================================================================

  defp init_enum_stream(enumerable, batch_size, encoded_seps, escape) do
    iterator =
      Enumerable.reduce(enumerable, {:cont, nil}, fn item, _acc -> {:suspend, item} end)

    {:enum, iterator, "", [], encoded_seps, escape, batch_size}
  end

  defp next_rows_enum(
         {:enum, {:suspended, chunk, continuation}, buffer, rows, encoded_seps, escape, batch_size}
       ) do
    chunk_binary = if is_binary(chunk), do: chunk, else: to_string(chunk)
    data = buffer <> chunk_binary

    {parsed, consumed} = ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

    {new_rows, remaining} =
      if consumed > 0 do
        {rows ++ parsed, binary_part(data, consumed, byte_size(data) - consumed)}
      else
        {rows, data}
      end

    next_iterator = continuation.({:cont, nil})

    if length(new_rows) >= batch_size do
      {to_emit, rest} = Enum.split(new_rows, batch_size)
      {to_emit, {:enum, next_iterator, remaining, rest, encoded_seps, escape, batch_size}}
    else
      next_rows_enum({:enum, next_iterator, remaining, new_rows, encoded_seps, escape, batch_size})
    end
  end

  defp next_rows_enum({:enum, {:done, _}, buffer, rows, encoded_seps, escape, batch_size}) do
    # Parse remaining buffer
    final_rows =
      if byte_size(buffer) > 0 do
        parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
        rows ++ parsed
      else
        rows
      end

    if final_rows == [] do
      {:halt, {:enum, {:done, nil}, "", [], encoded_seps, escape, batch_size}}
    else
      {final_rows, {:enum, {:done, nil}, "", [], encoded_seps, escape, batch_size}}
    end
  end

  defp next_rows_enum({:enum, {:halted, _}, buffer, rows, encoded_seps, escape, batch_size}) do
    # Stream was halted - finalize remaining
    final_rows =
      if byte_size(buffer) > 0 do
        parsed = ZigCSV.Native.parse_fast(buffer, encoded_seps, escape)
        rows ++ parsed
      else
        rows
      end

    if final_rows == [] do
      {:halt, {:enum, {:halted, nil}, "", [], encoded_seps, escape, batch_size}}
    else
      {final_rows, {:enum, {:halted, nil}, "", [], encoded_seps, escape, batch_size}}
    end
  end

  # ==========================================================================
  # Device Streaming (Private)
  # ==========================================================================

  defp init_device_stream(device, chunk_size, batch_size, encoded_seps, escape) do
    {:device, device, "", [], encoded_seps, escape, chunk_size, batch_size}
  end

  defp next_rows_device(
         {:device, device, buffer, rows, encoded_seps, escape, chunk_size, batch_size}
       ) do
    if length(rows) >= batch_size do
      {to_emit, rest} = Enum.split(rows, batch_size)
      {to_emit, {:device, device, buffer, rest, encoded_seps, escape, chunk_size, batch_size}}
    else
      read_and_process_device(device, buffer, rows, encoded_seps, escape, chunk_size, batch_size)
    end
  end

  defp next_rows_device({:device_done, rows}) do
    if rows == [] do
      {:halt, {:device_done, []}}
    else
      {rows, {:device_done, []}}
    end
  end

  defp read_and_process_device(device, buffer, rows, encoded_seps, escape, chunk_size, batch_size) do
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
        data = buffer <> chunk

        {parsed, consumed} = ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)

        {new_rows, remaining} =
          if consumed > 0 do
            {rows ++ parsed, binary_part(data, consumed, byte_size(data) - consumed)}
          else
            {rows, data}
          end

        if length(new_rows) >= batch_size do
          {to_emit, rest} = Enum.split(new_rows, batch_size)
          {to_emit, {:device, device, remaining, rest, encoded_seps, escape, chunk_size, batch_size}}
        else
          next_rows_device(
            {:device, device, remaining, new_rows, encoded_seps, escape, chunk_size, batch_size}
          )
        end
    end
  end
end
