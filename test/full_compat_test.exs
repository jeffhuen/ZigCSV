defmodule FullCompatTest do
  @moduledoc """
  Comprehensive compatibility tests that directly compare ZigCSV output
  with NimbleCSV output for all operations.

  These tests ensure ZigCSV is a true drop-in replacement.
  """
  use ExUnit.Case

  alias ZigCSV.RFC4180, as: Zig
  alias NimbleCSV.RFC4180, as: Nimble

  # Test data generators
  defp simple_csv, do: "name,age\njohn,27\njane,30\n"
  defp simple_csv_crlf, do: "name,age\r\njohn,27\r\njane,30\r\n"
  defp quoted_csv, do: ~s(name,comment\njohn,"hello, world"\njane,"say ""hi"""\n)
  defp multiline_csv, do: ~s(name,comment\njohn,"line1\nline2"\njane,normal\n)
  defp empty_fields_csv, do: "a,,b\n,c,\n"
  defp whitespace_csv, do: " a , b \n c , d \n"
  defp single_column_csv, do: "name\njohn\njane\n"
  defp no_trailing_newline, do: "name,age\njohn,27"
  defp empty_csv, do: ""
  defp only_header, do: "name,age\n"
  defp unicode_csv, do: "name,city\n\u00e9lise,Montr\u00e9al\n\u4e2d\u6587,\u5317\u4eac\n"

  defp complex_csv do
    """
    id,name,description,price,active
    1,Widget,"A simple widget, very useful",19.99,true
    2,"Super Gadget","The ""ultimate"" gadget",99.99,false
    3,Thing,"Multi
    line
    description",5.00,true
    4,,"Empty name field",0.00,false
    5,Item,"Has ""quotes"" and, commas",15.50,true
    """
  end

  describe "parse_string/2 compatibility" do
    test "simple CSV with headers skipped" do
      csv = simple_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "simple CSV without skipping headers" do
      csv = simple_csv()

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "CRLF line endings" do
      csv = simple_csv_crlf()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "quoted fields with commas" do
      csv = quoted_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "multiline quoted fields" do
      csv = multiline_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "empty fields" do
      csv = empty_fields_csv()

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "whitespace preserved" do
      csv = whitespace_csv()

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "single column" do
      csv = single_column_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "no trailing newline" do
      csv = no_trailing_newline()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "empty CSV" do
      csv = empty_csv()

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "only header row" do
      csv = only_header()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "unicode content" do
      csv = unicode_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "complex mixed CSV" do
      csv = complex_csv()

      assert Zig.parse_string(csv, skip_headers: true) ==
               Nimble.parse_string(csv, skip_headers: true)
    end

    test "quoted empty field" do
      csv = ~s("",a\n)

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "field with only quotes inside" do
      csv = ~s(""""\n)

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "multiple escaped quotes" do
      csv = ~s("a""b""c"\n)

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "quoted field with CRLF inside" do
      csv = ~s("line1\r\nline2"\n)

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end

    test "mixed quoted and unquoted" do
      csv = ~s(a,"b",c\n"d",e,"f"\n)

      assert Zig.parse_string(csv, skip_headers: false) ==
               Nimble.parse_string(csv, skip_headers: false)
    end
  end

  describe "parse_enumerable/2 compatibility" do
    test "list of lines" do
      lines = ["name,age\n", "john,27\n", "jane,30\n"]

      assert Zig.parse_enumerable(lines, skip_headers: true) ==
               Nimble.parse_enumerable(lines, skip_headers: true)
    end

    # Note: ZigCSV handles arbitrary binary chunks better than NimbleCSV.
    # NimbleCSV expects line-delimited input; ZigCSV properly buffers across chunk boundaries.
    test "chunked input - ZigCSV handles correctly, NimbleCSV does not" do
      chunks = ["name,a", "ge\njohn,", "27\njane,30\n"]
      # ZigCSV correctly parses across chunk boundaries
      assert Zig.parse_enumerable(chunks, skip_headers: true) == [["john", "27"], ["jane", "30"]]
      # NimbleCSV misparses chunked input because it treats each chunk as a
      # complete line. It splits on newlines within each chunk independently,
      # so partial lines at chunk boundaries produce wrong fields.
      nimble_result = Nimble.parse_enumerable(chunks, skip_headers: true)

      assert nimble_result != [["john", "27"], ["jane", "30"]],
             "NimbleCSV unexpectedly handled chunked input correctly"
    end

    test "quoted field split across chunks - ZigCSV handles correctly" do
      chunks = ["name,comment\njohn,\"hel", "lo, world\"\n"]
      # ZigCSV correctly handles quoted fields split across chunks
      assert Zig.parse_enumerable(chunks, skip_headers: true) == [["john", "hello, world"]]
      # NimbleCSV returns [] because the quoted field is split across chunks
      # and it doesn't buffer across chunk boundaries
      nimble_result = Nimble.parse_enumerable(chunks, skip_headers: true)

      assert nimble_result == [],
             "NimbleCSV unexpectedly handled split quoted field correctly"
    end
  end

  describe "parse_stream/2 compatibility" do
    test "basic stream" do
      lines = ["name,age\n", "john,27\n", "jane,30\n"]
      stream = Stream.map(lines, & &1)

      zig_result = Zig.parse_stream(stream, skip_headers: true) |> Enum.to_list()

      stream2 = Stream.map(lines, & &1)
      nimble_result = Nimble.parse_stream(stream2, skip_headers: true) |> Enum.to_list()

      assert zig_result == nimble_result
    end

    test "stream with transformation" do
      lines = ["name,age\n", "john,27\n"]
      stream = Stream.map(lines, &String.upcase/1)

      zig_result = Zig.parse_stream(stream, skip_headers: true) |> Enum.to_list()

      stream2 = Stream.map(lines, &String.upcase/1)
      nimble_result = Nimble.parse_stream(stream2, skip_headers: true) |> Enum.to_list()

      assert zig_result == nimble_result
    end

    test "stream content matches" do
      csv = complex_csv()
      path = "/tmp/compat_test_#{System.unique_integer([:positive])}.csv"
      File.write!(path, csv)
      on_exit(fn -> File.rm(path) end)

      zig_rows =
        File.stream!(path)
        |> Zig.parse_stream(skip_headers: true)
        |> Enum.to_list()

      nimble_rows =
        File.stream!(path)
        |> Nimble.parse_stream(skip_headers: true)
        |> Enum.to_list()

      assert zig_rows == nimble_rows
    end
  end

  describe "dump_to_iodata/1 compatibility" do
    test "simple rows" do
      rows = [["name", "age"], ["john", "27"]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "rows with commas" do
      rows = [["name", "comment"], ["john", "hello, world"]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "rows with quotes" do
      rows = [["name", "comment"], ["john", "say \"hi\""]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "rows with newlines" do
      rows = [["name", "comment"], ["john", "line1\nline2"]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "empty fields" do
      rows = [["a", "", "b"], ["", "c", ""]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "integer and atom values" do
      rows = [["name", "count", "status"], ["item", 42, :active]]

      assert IO.iodata_to_binary(Zig.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end
  end

  describe "dump_to_stream/1 compatibility" do
    test "stream output matches" do
      rows = [["name", "age"], ["john", "27"], ["jane", "30"]]

      zig_result = Zig.dump_to_stream(rows) |> Enum.to_list() |> IO.iodata_to_binary()
      nimble_result = Nimble.dump_to_stream(rows) |> Enum.to_list() |> IO.iodata_to_binary()

      assert zig_result == nimble_result
    end
  end

  describe "to_line_stream/1 compatibility" do
    test "converts chunks to lines" do
      chunks = ["name,age\njohn,", "27\njane,30\n"]

      zig_result = Zig.to_line_stream(chunks) |> Enum.to_list()
      nimble_result = Nimble.to_line_stream(chunks) |> Enum.to_list()

      assert zig_result == nimble_result
    end

    test "handles CRLF" do
      chunks = ["name,age\r\njohn,27\r\n"]

      zig_result = Zig.to_line_stream(chunks) |> Enum.to_list()
      nimble_result = Nimble.to_line_stream(chunks) |> Enum.to_list()

      assert zig_result == nimble_result
    end
  end

  describe "round-trip compatibility" do
    test "parse then dump produces same result" do
      original = [["name", "age"], ["john", "27"], ["jane", "30"]]

      zig_dumped = Zig.dump_to_iodata(original) |> IO.iodata_to_binary()
      nimble_dumped = Nimble.dump_to_iodata(original) |> IO.iodata_to_binary()

      assert zig_dumped == nimble_dumped

      zig_parsed = Zig.parse_string(zig_dumped, skip_headers: false)
      nimble_parsed = Nimble.parse_string(nimble_dumped, skip_headers: false)

      assert zig_parsed == nimble_parsed
      assert zig_parsed == original
    end

    test "complex round-trip" do
      original = [
        ["id", "name", "description"],
        ["1", "Widget", "A \"great\" widget, really"],
        ["2", "Gadget", "Multi\nline\ndesc"],
        ["3", "", "Empty name"]
      ]

      zig_dumped = Zig.dump_to_iodata(original) |> IO.iodata_to_binary()
      nimble_dumped = Nimble.dump_to_iodata(original) |> IO.iodata_to_binary()

      assert zig_dumped == nimble_dumped

      zig_parsed = Zig.parse_string(zig_dumped, skip_headers: false)
      nimble_parsed = Nimble.parse_string(nimble_dumped, skip_headers: false)

      assert zig_parsed == nimble_parsed
    end
  end

  describe "all ZigCSV strategies produce NimbleCSV-compatible output" do
    @strategies [:basic, :simd, :parallel, :zero_copy]

    test "simple CSV" do
      csv = simple_csv()
      expected = Nimble.parse_string(csv, skip_headers: true)

      for strategy <- @strategies do
        result = Zig.parse_string(csv, skip_headers: true, strategy: strategy)
        assert result == expected, "Strategy #{strategy} failed for simple CSV"
      end
    end

    test "complex CSV" do
      csv = complex_csv()
      expected = Nimble.parse_string(csv, skip_headers: true)

      for strategy <- @strategies do
        result = Zig.parse_string(csv, skip_headers: true, strategy: strategy)
        assert result == expected, "Strategy #{strategy} failed for complex CSV"
      end
    end

    test "quoted CSV" do
      csv = quoted_csv()
      expected = Nimble.parse_string(csv, skip_headers: true)

      for strategy <- @strategies do
        result = Zig.parse_string(csv, skip_headers: true, strategy: strategy)
        assert result == expected, "Strategy #{strategy} failed for quoted CSV"
      end
    end

    test "multiline CSV" do
      csv = multiline_csv()
      expected = Nimble.parse_string(csv, skip_headers: true)

      for strategy <- @strategies do
        result = Zig.parse_string(csv, skip_headers: true, strategy: strategy)
        assert result == expected, "Strategy #{strategy} failed for multiline CSV"
      end
    end
  end

  describe "options/0" do
    # Note: NimbleCSV.RFC4180 does not have options/0
    # This is a ZigCSV extension for introspection
    test "ZigCSV provides options/0 for introspection" do
      opts = Zig.options()
      assert Keyword.keyword?(opts)
      assert Keyword.get(opts, :separator) == ","
      assert Keyword.get(opts, :escape) == "\""
    end
  end
end
