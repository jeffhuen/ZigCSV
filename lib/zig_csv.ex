defmodule ZigCSV do
  @moduledoc ~S"""
  ZigCSV is an ultra-fast CSV parsing and dumping library powered by purpose-built Zig NIFs.

  It provides a drop-in replacement for NimbleCSV with the same API, while offering
  multiple parsing strategies optimized for different use cases.

  ## Quick Start

  Use the pre-defined `ZigCSV.RFC4180` parser:

      alias ZigCSV.RFC4180, as: CSV

      CSV.parse_string("name,age\njohn,27\n")
      #=> [["john", "27"]]

      CSV.parse_string("name,age\njohn,27\n", skip_headers: false)
      #=> [["name", "age"], ["john", "27"]]

  ## Defining Custom Parsers

  You can define custom CSV parsers with `define/2`:

      ZigCSV.define(MyParser,
        separator: ",",
        escape: "\"",
        line_separator: "\n"
      )

      MyParser.parse_string("a,b\n1,2\n")
      #=> [["1", "2"]]

  ## Multi-Separator Support

  ZigCSV supports multiple separators (NimbleCSV-compatible):

      ZigCSV.define(MyParser,
        separator: [",", "|"],
        escape: "\""
      )

      MyParser.parse_string("a,b|c\n", skip_headers: false)
      #=> [["a", "b", "c"]]

  Multi-byte separators are also supported:

      ZigCSV.define(MyParser,
        separator: "||",
        escape: "\""
      )

  ## Parsing Strategies

  ZigCSV supports multiple parsing strategies via the `:strategy` option:

    * `:simd` - SIMD-accelerated scanning via Zig @Vector (default, fastest for most files)
    * `:basic` - Scalar parsing (same as :simd; scanner has automatic scalar fallback)
    * `:parallel` - Currently aliases :simd; reserved for future multi-threaded support
    * `:zero_copy` - Sub-binary references (NimbleCSV-like memory profile, max speed)

  Example:

      CSV.parse_string(large_csv, strategy: :parallel)

  ## Streaming

  For large files, use `parse_stream/2` which uses a bounded-memory streaming parser:

      "huge.csv"
      |> File.stream!()
      |> CSV.parse_stream()
      |> Stream.each(&process_row/1)
      |> Stream.run()

  ## Dumping

  Convert rows back to CSV format:

      CSV.dump_to_iodata([["name", "age"], ["john", "27"]])
      #=> "name,age\njohn,27\n"

  ## NimbleCSV Compatibility

  ZigCSV is designed as a drop-in replacement for NimbleCSV. The API is identical:

    * `parse_string/2` - Parse CSV string to list of rows
    * `parse_stream/2` - Lazily parse a stream
    * `parse_enumerable/2` - Parse any enumerable
    * `dump_to_iodata/1` - Convert rows to iodata
    * `dump_to_stream/1` - Lazily convert rows to iodata stream
    * `to_line_stream/1` - Convert arbitrary chunks to lines
    * `options/0` - Return module configuration

  The only behavioral difference is that ZigCSV adds the `:strategy` option
  for selecting the parsing approach.

  ## Edge Cases

  **Unterminated quoted fields**: An opening quote with no closing quote raises
  `ZigCSV.ParseError`, matching NimbleCSV behavior.

  **Unexpected escape characters**: A quote character appearing inside an
  unquoted field raises `ZigCSV.ParseError`, matching NimbleCSV behavior.

  ## Encoding Support

  ZigCSV supports character encoding conversion via the `:encoding` option:

      ZigCSV.define(MySpreadsheet,
        separator: "\t",
        encoding: {:utf16, :little},
        trim_bom: true,
        dump_bom: true
      )

  Supported encodings:
    * `:utf8` - UTF-8 (default, no conversion overhead)
    * `:latin1` - ISO-8859-1 / Latin-1
    * `{:utf16, :little}` - UTF-16 Little Endian
    * `{:utf16, :big}` - UTF-16 Big Endian
    * `{:utf32, :little}` - UTF-32 Little Endian
    * `{:utf32, :big}` - UTF-32 Big Endian

  Use `ZigCSV.Spreadsheet` for Excel-compatible UTF-16 LE tab-separated values.

  """

  # ==========================================================================
  # Types
  # ==========================================================================

  @typedoc """
  A single row of CSV data, represented as a list of field binaries.
  """
  @type row :: [binary()]

  @typedoc """
  Multiple rows of CSV data.
  """
  @type rows :: [row()]

  @typedoc """
  Parsing strategy to use.

  ## Available Strategies

    * `:simd` - SIMD-accelerated scanning via Zig @Vector (default, fastest for most files)
    * `:basic` - Scalar parsing (same as :simd; scanner has automatic scalar fallback)
    * `:parallel` - Currently aliases :simd; reserved for future multi-threaded support
    * `:zero_copy` - Sub-binary references (maximum speed, keeps parent binary alive)

  ## Memory Model Comparison

  | Strategy | Memory Model | Input Binary | Best When |
  |----------|--------------|--------------|-----------|
  | `:simd` | Copy | Freed immediately | Default, memory-constrained |
  | `:basic` | Copy | Freed immediately | Debugging, baseline |
  | `:parallel` | Copy | Freed immediately | Large files, complex CSVs |
  | `:zero_copy` | Sub-binary | Kept alive | Speed-critical, short-lived |

  ## Examples

      # Default SIMD strategy
      CSV.parse_string(data)

      # Parallel for large files
      CSV.parse_string(large_data, strategy: :parallel)

      # Zero-copy for maximum speed
      CSV.parse_string(data, strategy: :zero_copy)

  """
  @type strategy :: :simd | :basic | :parallel | :zero_copy

  @typedoc """
  Options for parsing functions.

  ## Common Options

    * `:skip_headers` - When `true`, skips the first row. Defaults to `true`.
    * `:strategy` - The parsing strategy to use. One of:
      * `:simd` - SIMD-accelerated (default)
      * `:basic` - Scalar parsing (same as :simd)
      * `:parallel` - Currently aliases :simd
      * `:zero_copy` - Sub-binary references (keeps parent binary alive)

  ## Streaming Options

    * `:chunk_size` - Bytes per IO read for streaming. Defaults to `65536`.
    * `:batch_size` - Rows per batch for streaming. Defaults to `1000`.

  """
  @type parse_options :: [
          skip_headers: boolean(),
          strategy: strategy(),
          chunk_size: pos_integer(),
          batch_size: pos_integer()
        ]

  @typedoc """
  Encoding for CSV data.

  Supported encodings:
    * `:utf8` - UTF-8 (default, no conversion)
    * `:latin1` - ISO-8859-1 / Latin-1
    * `{:utf16, :little}` - UTF-16 Little Endian
    * `{:utf16, :big}` - UTF-16 Big Endian
    * `{:utf32, :little}` - UTF-32 Little Endian
    * `{:utf32, :big}` - UTF-32 Big Endian
  """
  @type encoding :: :utf8 | :latin1 | {:utf16, :little | :big} | {:utf32, :little | :big}

  @typedoc """
  Options for `define/2`.

  ## Parsing Options

    * `:separator` - Field separator. A string like `","` or a list of strings
      like `[",", "|"]` for multi-separator support. Multi-byte separators
      like `"||"` are also supported. Defaults to `","`.

    * `:escape` - Escape/quote string. Can be multi-byte. Defaults to `"\""`.

    * `:newlines` - List of recognized line endings. Defaults to `["\r\n", "\n"]`.
    * `:trim_bom` - Remove BOM when parsing strings. Defaults to `false`.
    * `:encoding` - Character encoding. Defaults to `:utf8`. See `t:encoding/0`.

  ## Dumping Options

    * `:line_separator` - Line separator for output. Defaults to `"\n"`.

    * `:dump_bom` - Include BOM in output. Defaults to `false`.

    * `:reserved` - Additional characters requiring escaping.
    * `:escape_formula` - Map for formula injection prevention. Defaults to `nil`.

  ## Other Options

    * `:strategy` - Default parsing strategy. Defaults to `:simd`.
    * `:moduledoc` - Documentation for the generated module.

  """
  @type define_options :: [
          separator: String.t() | [String.t()],
          escape: String.t(),
          newlines: [String.t()],
          line_separator: String.t(),
          trim_bom: boolean(),
          dump_bom: boolean(),
          reserved: [String.t()],
          escape_formula: map() | nil,
          encoding: encoding(),
          strategy: strategy(),
          moduledoc: String.t() | false | nil
        ]

  # ==========================================================================
  # Exceptions
  # ==========================================================================

  defmodule ParseError do
    @moduledoc """
    Exception raised when CSV parsing fails.

    ## Fields

      * `:message` - Human-readable error description

    """
    defexception [:message]

    @impl true
    def message(%{message: message}), do: message
  end

  # ==========================================================================
  # Callbacks (Behaviour)
  # ==========================================================================

  @doc """
  Returns the options used to define this CSV module.
  """
  @callback options() :: keyword()

  @doc """
  Parses a CSV string into a list of rows.
  """
  @callback parse_string(binary()) :: rows()

  @doc """
  Parses a CSV string into a list of rows with options.
  """
  @callback parse_string(binary(), parse_options()) :: rows()

  @doc """
  Lazily parses a stream of CSV data into a stream of rows.
  """
  @callback parse_stream(Enumerable.t()) :: Enumerable.t()

  @doc """
  Lazily parses a stream of CSV data into a stream of rows with options.
  """
  @callback parse_stream(Enumerable.t(), parse_options()) :: Enumerable.t()

  @doc """
  Eagerly parses an enumerable of CSV data into a list of rows.
  """
  @callback parse_enumerable(Enumerable.t()) :: rows()

  @doc """
  Eagerly parses an enumerable of CSV data into a list of rows with options.
  """
  @callback parse_enumerable(Enumerable.t(), parse_options()) :: rows()

  @doc """
  Converts rows to iodata in CSV format.
  """
  @callback dump_to_iodata(Enumerable.t()) :: iodata()

  @doc """
  Lazily converts rows to a stream of iodata in CSV format.
  """
  @callback dump_to_stream(Enumerable.t()) :: Enumerable.t()

  @doc """
  Converts a stream of arbitrary binary chunks into a line-oriented stream.
  """
  @callback to_line_stream(Enumerable.t()) :: Enumerable.t()

  # ==========================================================================
  # Module Definition
  # ==========================================================================

  @doc ~S"""
  Defines a new CSV parser/dumper module.

  ## Options

  ### Parsing Options

    * `:separator` - The field separator. A string like `","` or a list of strings
      like `[",", "|"]`. Multi-byte separators like `"||"` are also supported.
      Defaults to `","`.

    * `:escape` - The escape/quote string. Can be multi-byte.
      Defaults to `"\""`.

    * `:newlines` - List of recognized line endings for parsing.
      Defaults to `["\r\n", "\n"]`. Both CRLF and LF are always recognized.

    * `:trim_bom` - When `true`, removes the BOM (byte order marker)
      from the beginning of strings before parsing. Defaults to `false`.

    * `:encoding` - Character encoding for input/output. Defaults to `:utf8`.
      Supported encodings:
      * `:utf8` - UTF-8 (default, no conversion overhead)
      * `:latin1` - ISO-8859-1 / Latin-1
      * `{:utf16, :little}` - UTF-16 Little Endian
      * `{:utf16, :big}` - UTF-16 Big Endian
      * `{:utf32, :little}` - UTF-32 Little Endian
      * `{:utf32, :big}` - UTF-32 Big Endian

      When encoding is not `:utf8`, input data is converted to UTF-8 for
      parsing, and output is converted back to the target encoding.

  ### Dumping Options

    * `:line_separator` - The line separator for dumped output.
      Defaults to `"\n"`.

    * `:dump_bom` - When `true`, includes the appropriate BOM at the start of
      dumped output. Defaults to `false`.

    * `:reserved` - Additional characters that should trigger field escaping
      when dumping. By default, fields containing the separator, escape
      character, or newlines are escaped.

    * `:escape_formula` - A map of characters to their escaped versions
      for preventing CSV formula injection. When set, fields starting with
      these characters will be prefixed with a tab. Defaults to `nil`.

      Example: `%{"=" => true, "+" => true, "-" => true, "@" => true}`

  ### Strategy Options

    * `:strategy` - The default parsing strategy. One of:
      * `:simd` - SIMD-accelerated via Zig @Vector (default, fastest)
      * `:basic` - Scalar parsing (same as :simd; scanner has automatic scalar fallback)
      * `:parallel` - Currently aliases :simd; reserved for future multi-threaded support
      * `:zero_copy` - Sub-binary references (NimbleCSV-like memory, max speed)

  ### Documentation

    * `:moduledoc` - The `@moduledoc` for the generated module.
      Set to `false` to disable documentation.

  ## Examples

      # Define a standard CSV parser
      ZigCSV.define(MyApp.CSV,
        separator: ",",
        escape: "\"",
        line_separator: "\n"
      )

      # Use it
      MyApp.CSV.parse_string("a,b\n1,2\n")
      #=> [["1", "2"]]

      # Define a multi-separator parser
      ZigCSV.define(MyApp.FlexCSV,
        separator: [",", "|"],
        escape: "\""
      )

      # Define a UTF-16 spreadsheet parser
      ZigCSV.define(MyApp.Spreadsheet,
        separator: "\t",
        encoding: {:utf16, :little},
        trim_bom: true,
        dump_bom: true
      )

      # Get the configuration
      MyApp.CSV.options()
      #=> [separator: ",", escape: "\"", ...]

  """
  @spec define(module(), define_options()) :: :ok
  def define(module, options \\ []) do
    config = extract_and_validate_options(options)
    compile_module(module, config)
    :ok
  end

  # ==========================================================================
  # Separator Encoding
  # ==========================================================================

  @doc """
  Encodes a list of separator strings into the binary format expected by NIF functions.

  The encoded format is `<<count::8, len1::8, sep1::binary-size(len1), ...>>`.

  ## Examples

      iex> ZigCSV.encode_separators([","])
      <<1, 1, ?,>>

      iex> ZigCSV.encode_separators([",", "|"])
      <<2, 1, ?,, 1, ?|>>

      iex> ZigCSV.encode_separators("||")
      <<1, 2, ?|, ?|>>

  """
  @spec encode_separators(String.t() | [String.t()]) :: binary()
  def encode_separators(separators) when is_list(separators) do
    count = length(separators)
    encoded_parts = for sep <- separators, do: <<byte_size(sep)::8, sep::binary>>
    <<count::8, IO.iodata_to_binary(encoded_parts)::binary>>
  end

  def encode_separators(separator) when is_binary(separator) do
    encode_separators([separator])
  end

  # ==========================================================================
  # Private: Option Extraction and Validation
  # ==========================================================================

  defp extract_and_validate_options(options) do
    separator = Keyword.get(options, :separator, ",")
    escape = Keyword.get(options, :escape, "\"")

    # Normalize separator to list
    separators = normalize_separators(separator)
    validate_separators!(separators)
    validate_escape!(escape)

    # For dumping, use the first separator
    primary_separator = hd(separators)

    line_separator = Keyword.get(options, :line_separator, "\n")
    newlines = Keyword.get(options, :newlines, ["\r\n", "\n"])
    trim_bom = Keyword.get(options, :trim_bom, false)
    dump_bom = Keyword.get(options, :dump_bom, false)
    escape_formula = Keyword.get(options, :escape_formula, nil)
    default_strategy = Keyword.get(options, :strategy, :simd)
    moduledoc = Keyword.get(options, :moduledoc)

    # Encoding support
    encoding = Keyword.get(options, :encoding, :utf8)
    validate_encoding!(encoding)
    bom = :unicode.encoding_to_bom(encoding)
    encoded_newlines = Enum.map(newlines, &:unicode.characters_to_binary(&1, :utf8, encoding))

    # Encode config for NIF
    encoded_seps = encode_separators(separators)

    # Build escape_chars for dump escaping — matches NimbleCSV's @reserved default.
    # :reserved option replaces the entire default list (not appends), per NimbleCSV behavior.
    escape_chars =
      Enum.uniq(
        Keyword.get(
          options,
          :reserved,
          [escape, line_separator] ++ separators ++ newlines
        )
      )

    stored_options = [
      separator: separator,
      escape: escape,
      line_separator: line_separator,
      newlines: newlines,
      trim_bom: trim_bom,
      dump_bom: dump_bom,
      reserved: escape_chars,
      escape_formula: escape_formula,
      encoding: encoding,
      strategy: default_strategy
    ]

    %{
      separator: separator,
      separators: separators,
      primary_separator: primary_separator,
      encoded_seps: encoded_seps,
      escape: escape,
      line_separator: line_separator,
      newlines: newlines,
      trim_bom: trim_bom,
      dump_bom: dump_bom,
      escape_chars: escape_chars,
      escape_formula: escape_formula,
      default_strategy: default_strategy,
      stored_options: stored_options,
      moduledoc: moduledoc,
      encoding: encoding,
      bom: bom,
      encoded_newlines: encoded_newlines
    }
  end

  defp normalize_separators(sep) when is_binary(sep), do: [sep]
  defp normalize_separators(seps) when is_list(seps), do: seps

  defp validate_separators!(separators) do
    for sep <- separators do
      unless is_binary(sep) and byte_size(sep) > 0 do
        raise ArgumentError,
              "ZigCSV requires each separator to be a non-empty binary, got: #{inspect(sep)}"
      end

      if byte_size(sep) > 16 do
        raise ArgumentError,
              "ZigCSV separator must be at most 16 bytes, got: #{inspect(sep)} (#{byte_size(sep)} bytes)"
      end
    end

    if separators == [] do
      raise ArgumentError, "ZigCSV requires at least one separator"
    end

    if length(separators) > 8 do
      raise ArgumentError, "ZigCSV supports at most 8 separators, got: #{length(separators)}"
    end
  end

  defp validate_escape!(escape) do
    unless is_binary(escape) and byte_size(escape) > 0 do
      raise ArgumentError,
            "ZigCSV requires escape to be a non-empty binary, got: #{inspect(escape)}"
    end

    if byte_size(escape) > 16 do
      raise ArgumentError,
            "ZigCSV escape must be at most 16 bytes, got: #{inspect(escape)} (#{byte_size(escape)} bytes)"
    end
  end

  defp validate_encoding!(encoding) when encoding in [:utf8, :latin1], do: :ok
  defp validate_encoding!({:utf16, endian}) when endian in [:little, :big], do: :ok
  defp validate_encoding!({:utf32, endian}) when endian in [:little, :big], do: :ok

  defp validate_encoding!(encoding) do
    raise ArgumentError,
          "Invalid encoding: #{inspect(encoding)}. " <>
            "Supported: :utf8, :latin1, {:utf16, :little}, {:utf16, :big}, {:utf32, :little}, {:utf32, :big}"
  end

  # ==========================================================================
  # Private: Module Compilation
  # ==========================================================================

  defp compile_module(module, config) do
    quoted_ast =
      quote do
        defmodule unquote(module) do
          unquote(quoted_module_header(config))
          unquote(quoted_config_function(config))
          unquote_splicing(quoted_parsing_functions(config))
          unquote(quoted_dumping_functions(config))
        end
      end

    Code.compile_quoted(quoted_ast)
  end

  # ==========================================================================
  # Private: AST Generation Helpers
  # ==========================================================================

  defp quoted_module_header(config) do
    quote do
      @moduledoc unquote(Macro.escape(config.moduledoc))
      @behaviour ZigCSV

      @separator unquote(Macro.escape(config.primary_separator))
      @separators unquote(Macro.escape(config.separators))
      @encoded_seps unquote(Macro.escape(config.encoded_seps))
      @escape unquote(Macro.escape(config.escape))
      @line_separator unquote(Macro.escape(config.line_separator))
      @newlines unquote(Macro.escape(config.newlines))
      @trim_bom unquote(Macro.escape(config.trim_bom))
      @dump_bom unquote(Macro.escape(config.dump_bom))
      @escape_chars unquote(Macro.escape(config.escape_chars))
      @escape_formula unquote(Macro.escape(config.escape_formula))
      @default_strategy unquote(Macro.escape(config.default_strategy))
      @stored_options unquote(Macro.escape(config.stored_options))
      @encoding unquote(Macro.escape(config.encoding))
      @bom unquote(Macro.escape(config.bom))
      @encoded_newlines unquote(Macro.escape(config.encoded_newlines))
    end
  end

  defp quoted_config_function(config) do
    quote do
      @doc """
      Returns the options used to define this CSV module.
      """
      @impl ZigCSV
      @spec options() :: keyword()
      def options, do: unquote(Macro.escape(config.stored_options))
    end
  end

  defp quoted_parsing_functions(config) do
    List.flatten([
      quoted_parse_string_function(config),
      quoted_parse_stream_function(),
      quoted_parse_enumerable_function(),
      quoted_to_line_stream_function()
    ])
  end

  defp quoted_parse_string_function(config) do
    [
      quoted_parse_string_main(config.encoding),
      quoted_maybe_trim_bom(config.trim_bom),
      quoted_maybe_to_utf8(config.encoding),
      quoted_inline_encoding_helpers(),
      quoted_do_parse_string_clauses()
    ]
  end

  defp quoted_inline_encoding_helpers do
    quote do
      @compile {:inline,
                maybe_dump_bom: 1, maybe_trim_bom: 1, maybe_to_utf8: 1, maybe_to_encoding: 1}
    end
  end

  defp quoted_parse_string_main(encoding) do
    encoding_doc =
      if encoding == :utf8,
        do: "",
        else:
          "\n\n  Input is expected in #{inspect(encoding)} encoding and will be converted to UTF-8 for parsing."

    quote do
      @doc """
      Parses a CSV string into a list of rows.

      ## Options

        * `:skip_headers` - When `true`, skips the first row. Defaults to `true`.
        * `:strategy` - The parsing strategy. Defaults to `#{inspect(@default_strategy)}`.
      #{unquote(encoding_doc)}
      """
      @impl ZigCSV
      @spec parse_string(binary(), ZigCSV.parse_options()) :: ZigCSV.rows()
      def parse_string(string, opts \\ [])

      def parse_string(string, opts) when is_binary(string) and is_list(opts) do
        strategy = Keyword.get(opts, :strategy, @default_strategy)
        skip_headers = Keyword.get(opts, :skip_headers, true)

        string = string |> maybe_trim_bom() |> maybe_to_utf8()
        rows = do_parse_string(string, strategy)

        case {skip_headers, rows} do
          {true, [_ | tail]} -> tail
          _ -> rows
        end
      end
    end
  end

  defp quoted_maybe_trim_bom(true) do
    quote do
      defp maybe_trim_bom(<<@bom, rest::binary>>), do: rest
      defp maybe_trim_bom(string), do: string
    end
  end

  defp quoted_maybe_trim_bom(false) do
    quote do
      defp maybe_trim_bom(string), do: string
    end
  end

  # For UTF-8, encoding conversion is a no-op
  defp quoted_maybe_to_utf8(:utf8) do
    quote do
      defp maybe_to_utf8(data), do: data
    end
  end

  # For other encodings, convert to UTF-8 using :unicode module
  defp quoted_maybe_to_utf8(encoding) do
    quote do
      defp maybe_to_utf8(data) do
        case :unicode.characters_to_binary(data, unquote(Macro.escape(encoding)), :utf8) do
          binary when is_binary(binary) ->
            binary

          {:incomplete, converted, rest} ->
            raise ZigCSV.ParseError,
              message:
                "Incomplete #{inspect(unquote(Macro.escape(encoding)))} sequence: " <>
                  "converted #{byte_size(converted)} bytes, #{byte_size(rest)} bytes remaining"

          {:error, converted, rest} ->
            raise ZigCSV.ParseError,
              message:
                "Invalid #{inspect(unquote(Macro.escape(encoding)))} sequence at byte #{byte_size(converted)}: " <>
                  "#{inspect(binary_part(rest, 0, min(byte_size(rest), 10)))}"
        end
      end
    end
  end

  defp quoted_do_parse_string_clauses do
    quote do
      defp do_parse_string(string, strategy) do
        result =
          case strategy do
            :basic -> ZigCSV.Native.parse_basic(string, @encoded_seps, @escape)
            :simd -> ZigCSV.Native.parse_fast(string, @encoded_seps, @escape)
            :parallel -> ZigCSV.Native.parse_parallel(string, @encoded_seps, @escape)
            :zero_copy -> ZigCSV.Native.parse_zero_copy(string, @encoded_seps, @escape)
          end

        handle_parse_result(result, string)
      end

      unquote(quoted_handle_parse_result())
      unquote(quoted_extract_error_line())
    end
  end

  defp quoted_handle_parse_result do
    quote do
      defp handle_parse_result(rows, _string) when is_list(rows), do: rows

      defp handle_parse_result({:partial, :unterminated_escape, _rows}, _string) do
        raise ZigCSV.ParseError,
          message: "expected escape character #{@escape} but reached the end of file"
      end

      defp handle_parse_result({:partial, {:unexpected_escape, byte_pos}, _rows}, string) do
        line = extract_error_line(string, byte_pos)

        raise ZigCSV.ParseError,
          message: "unexpected escape character #{@escape} in #{inspect(line)}"
      end

      defp handle_parse_result({:partial, :oom, _rows}, _string) do
        raise ZigCSV.ParseError,
          message: "out of memory during CSV parsing"
      end

      defp handle_parse_result(:error, _string) do
        raise ZigCSV.ParseError,
          message: "NIF parse failed: could not inspect input binary"
      end

      defp handle_parse_result(other, _string) do
        raise ZigCSV.ParseError,
          message: "unexpected NIF result: #{inspect(other)}"
      end
    end
  end

  defp quoted_extract_error_line do
    quote do
      defp extract_error_line(string, byte_pos) do
        byte_pos = min(byte_pos, byte_size(string))
        before = binary_part(string, 0, byte_pos)

        line_start =
          case :binary.matches(before, ["\r\n", "\n"]) do
            [] ->
              0

            matches ->
              {pos, len} = List.last(matches)
              pos + len
          end

        remaining = binary_part(string, byte_pos, byte_size(string) - byte_pos)

        line_end =
          case :binary.match(remaining, ["\r\n", "\n"]) do
            {pos, len} -> byte_pos + pos + len
            :nomatch -> byte_size(string)
          end

        binary_part(string, line_start, line_end - line_start)
      end
    end
  end

  defp quoted_parse_stream_function do
    quote do
      @doc """
      Lazily parses a stream of CSV data into a stream of rows.
      """
      @impl ZigCSV
      @spec parse_stream(Enumerable.t(), ZigCSV.parse_options()) :: Enumerable.t()
      def parse_stream(stream, opts \\ [])

      def parse_stream(stream, opts) when is_list(opts) do
        skip_headers = Keyword.get(opts, :skip_headers, true)
        chunk_size = Keyword.get(opts, :chunk_size, 64 * 1024)
        batch_size = Keyword.get(opts, :batch_size, 1000)

        result_stream =
          ZigCSV.Streaming.stream_enumerable(stream,
            chunk_size: chunk_size,
            batch_size: batch_size,
            encoded_seps: @encoded_seps,
            escape: @escape,
            encoding: @encoding,
            bom: @bom,
            trim_bom: @trim_bom
          )

        if skip_headers do
          Stream.drop(result_stream, 1)
        else
          result_stream
        end
      end
    end
  end

  defp quoted_parse_enumerable_function do
    quote do
      @doc """
      Eagerly parses an enumerable of CSV data into a list of rows.
      """
      @impl ZigCSV
      @spec parse_enumerable(Enumerable.t(), ZigCSV.parse_options()) :: ZigCSV.rows()
      def parse_enumerable(enumerable, opts \\ [])

      def parse_enumerable(enumerable, opts) when is_list(opts) do
        string = Enum.join(enumerable, "")
        parse_string(string, opts)
      end
    end
  end

  defp quoted_to_line_stream_function do
    quote do
      @doc """
      Converts a stream of arbitrary binary chunks into a line-oriented stream.

      Each emitted line includes the line terminator (\\n or \\r\\n) at the end,
      matching NimbleCSV behavior.
      """
      @impl ZigCSV
      @spec to_line_stream(Enumerable.t()) :: Enumerable.t()
      def to_line_stream(stream) do
        newline = :binary.compile_pattern(@newlines)

        stream
        |> Stream.chunk_while(
          "",
          &to_line_stream_chunk_fun(&1, &2, newline),
          &to_line_stream_after_fun/1
        )
        |> Stream.concat()
      end

      defp to_line_stream_chunk_fun(element, acc, newline) do
        to_try = acc <> element
        {elements, acc} = chunk_by_newline(to_try, newline, [], {0, byte_size(to_try)})
        {:cont, elements, acc}
      end

      defp to_line_stream_after_fun(""), do: {:cont, []}
      defp to_line_stream_after_fun(acc), do: {:cont, [acc], []}

      @spec chunk_by_newline(binary, :binary.cp(), list(binary), tuple) :: {list(binary), binary}
      defp chunk_by_newline(_string, _newline, elements, {_offset, 0}) do
        {Enum.reverse(elements), ""}
      end

      defp chunk_by_newline(string, newline, elements, {offset, length}) do
        case :binary.match(string, newline, scope: {offset, length}) do
          {newline_offset, newline_length} ->
            difference = newline_length + newline_offset - offset
            element = binary_part(string, offset, difference)

            chunk_by_newline(
              string,
              newline,
              [element | elements],
              {newline_offset + newline_length, length - difference}
            )

          :nomatch ->
            {Enum.reverse(elements), binary_part(string, offset, length)}
        end
      end
    end
  end

  # Encode a UTF-8 string to target encoding, using integer form for single bytes
  # to match NimbleCSV's iodata structure
  defp encode_delimiter(value, encoding) do
    case :unicode.characters_to_binary(value, :utf8, encoding) do
      <<x>> -> x
      x -> x
    end
  end

  defp quoted_dumping_functions(config) do
    escape_formula_ast = quoted_escape_formula_function(config.escape_formula)
    maybe_to_encoding_ast = quoted_maybe_to_encoding(config.encoding)
    maybe_dump_bom_ast = quoted_maybe_dump_bom(config.dump_bom)

    encoded_separator = encode_delimiter(config.primary_separator, config.encoding)
    encoded_escape = encode_delimiter(config.escape, config.encoding)
    encoded_line_separator = encode_delimiter(config.line_separator, config.encoding)

    quote do
      # Pre-encoded delimiters for dumping
      @encoded_separator unquote(Macro.escape(encoded_separator))
      @encoded_escape unquote(Macro.escape(encoded_escape))
      @encoded_line_separator unquote(Macro.escape(encoded_line_separator))
      @replacement @escape <> @escape

      unquote(maybe_dump_bom_ast)

      @doc """
      Converts an enumerable of rows to iodata in CSV format.
      """
      @impl ZigCSV
      @spec dump_to_iodata(Enumerable.t()) :: iodata()
      def dump_to_iodata(enumerable) do
        check = init_dumper()

        enumerable
        |> Enum.map(&dump(&1, check))
        |> maybe_dump_bom()
      end

      @doc """
      Lazily converts an enumerable of rows to a stream of iodata.
      """
      @impl ZigCSV
      @spec dump_to_stream(Enumerable.t()) :: Enumerable.t()
      def dump_to_stream(enumerable) do
        check = init_dumper()

        enumerable
        |> Stream.map(&dump(&1, check))
        |> maybe_dump_bom()
      end

      defp init_dumper do
        :binary.compile_pattern(@escape_chars)
      end

      unquote(quoted_dump_helpers())

      unquote(escape_formula_ast)
      unquote(maybe_to_encoding_ast)

      @compile {:inline, init_dumper: 0, maybe_escape: 2}
    end
  end

  defp quoted_dump_helpers do
    quote do
      defp dump([], _check) do
        [@encoded_line_separator]
      end

      defp dump([entry], check) do
        [maybe_escape(entry, check), @encoded_line_separator]
      end

      defp dump([entry | entries], check) do
        [maybe_escape(entry, check), @encoded_separator | dump(entries, check)]
      end

      defp maybe_escape(entry, check) do
        entry = to_string(entry)

        case :binary.match(entry, check) do
          {_, _} ->
            replaced = :binary.replace(entry, @escape, @replacement, [:global])

            [
              @encoded_escape,
              maybe_escape_formula(entry),
              maybe_to_encoding(replaced),
              @encoded_escape
            ]

          :nomatch ->
            [maybe_escape_formula(entry), maybe_to_encoding(entry)]
        end
      end
    end
  end

  # For UTF-8, encoding conversion is a no-op (identity function)
  defp quoted_maybe_to_encoding(:utf8) do
    quote do
      defp maybe_to_encoding(data), do: data
    end
  end

  # For other encodings, convert from UTF-8 to target encoding
  defp quoted_maybe_to_encoding(encoding) do
    quote do
      defp maybe_to_encoding(data) do
        case :unicode.characters_to_binary(data, :utf8, unquote(Macro.escape(encoding))) do
          binary when is_binary(binary) ->
            binary

          {:error, _, _} ->
            raise ZigCSV.ParseError,
              message: "Cannot encode data to #{inspect(unquote(Macro.escape(encoding)))}"
        end
      end
    end
  end

  # Match NimbleCSV's maybe_dump_bom — handles both lists (dump_to_iodata) and
  # streams (dump_to_stream) with a single polymorphic private function.
  defp quoted_maybe_dump_bom(true) do
    quote do
      defp maybe_dump_bom(list) when is_list(list), do: [@bom | list]
      defp maybe_dump_bom(stream), do: Stream.concat([@bom], stream)
    end
  end

  defp quoted_maybe_dump_bom(false) do
    quote do
      defp maybe_dump_bom(data), do: data
    end
  end

  defp quoted_escape_formula_function(nil) do
    quote do
      defp maybe_escape_formula(_field), do: []
    end
  end

  defp quoted_escape_formula_function(escape_formula) do
    # NimbleCSV format: %{["@", "+", "-", "=", "\t", "\r"] => "'"}
    # Convert to list of {keys, value} pairs, then generate case clauses
    pairs = Enum.to_list(escape_formula)

    clauses =
      for {keys, value} <- pairs,
          key <- keys do
        quote do
          <<unquote(key) <> _>> -> unquote(value)
        end
      end

    catch_all = quote do: (_ -> [])
    all_clauses = List.flatten(clauses) ++ catch_all

    quote do
      defp maybe_escape_formula(field) do
        case field, do: unquote(all_clauses)
      end
    end
  end
end

# ==========================================================================
# Pre-defined Parsers
# ==========================================================================

ZigCSV.define(ZigCSV.RFC4180,
  separator: ",",
  escape: "\"",
  line_separator: "\r\n",
  newlines: ["\r\n", "\n"],
  strategy: :simd,
  moduledoc: ~S"""
  A CSV parser/dumper following RFC 4180 conventions.

  This module uses comma (`,`) as the field separator and double-quote (`"`)
  as the escape character. It recognizes both CRLF and LF line endings.

  This is a drop-in replacement for `NimbleCSV.RFC4180`.

  ## Quick Start

      alias ZigCSV.RFC4180, as: CSV

      # Parse CSV (skips headers by default)
      CSV.parse_string("name,age\njohn,27\n")
      #=> [["john", "27"]]

      # Include headers
      CSV.parse_string("name,age\njohn,27\n", skip_headers: false)
      #=> [["name", "age"], ["john", "27"]]

      # Use parallel parsing for large files
      CSV.parse_string(large_csv, strategy: :parallel)

      # Stream large files with bounded memory
      "huge.csv"
      |> File.stream!()
      |> CSV.parse_stream()
      |> Enum.each(&process/1)

  ## Dumping

      CSV.dump_to_iodata([["name", "age"], ["john", "27"]])
      |> IO.iodata_to_binary()
      #=> "name,age\njohn,27\n"

  ## Configuration

  This module was defined with:

      ZigCSV.define(ZigCSV.RFC4180,
        separator: ",",
        escape: "\"",
        line_separator: "\n",
        newlines: ["\r\n", "\n"],
        strategy: :simd
      )

  To customize these options, define your own parser with `ZigCSV.define/2`.

  """
)

ZigCSV.define(ZigCSV.Spreadsheet,
  separator: "\t",
  escape: "\"",
  line_separator: "\n",
  newlines: ["\r\n", "\n"],
  encoding: {:utf16, :little},
  trim_bom: true,
  dump_bom: true,
  strategy: :simd,
  moduledoc: ~S"""
  A spreadsheet-compatible parser using UTF-16 Little Endian encoding.

  This module uses tab (`\t`) as the field separator and double-quote (`"`)
  as the escape character. It handles UTF-16 LE encoding with BOM, which is
  the format commonly used by spreadsheet applications like Microsoft Excel.

  This is a drop-in replacement for `NimbleCSV.Spreadsheet`.

  ## Quick Start

      alias ZigCSV.Spreadsheet

      # Parse UTF-16 LE data (with BOM)
      Spreadsheet.parse_string(utf16_data, skip_headers: false)
      #=> [["name", "age"], ["john", "27"]]

      # Dump to UTF-16 LE format (includes BOM)
      Spreadsheet.dump_to_iodata([["name", "age"], ["john", "27"]])
      |> IO.iodata_to_binary()

  ## Configuration

  This module was defined with:

      ZigCSV.define(ZigCSV.Spreadsheet,
        separator: "\t",
        escape: "\"",
        encoding: {:utf16, :little},
        trim_bom: true,
        dump_bom: true
      )

  """
)
