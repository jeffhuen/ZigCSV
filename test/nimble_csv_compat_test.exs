defmodule NimbleCSVCompatTest do
  @moduledoc """
  Tests adapted from NimbleCSV to verify ZigCSV is a drop-in replacement.

  Source: https://github.com/dashbitco/nimble_csv/blob/master/test/nimble_csv_test.exs

  Every assertion compares ZigCSV output directly against NimbleCSV output.
  """
  use ExUnit.Case

  alias NimbleCSV.RFC4180, as: Nimble
  alias ZigCSV.RFC4180, as: CSV

  describe "parse_string/2" do
    test "with headers (skip_headers: true to match NimbleCSV default)" do
      input = "name,last,year\njohn,doe,1986\n"

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end

    test "without skipping headers" do
      input = "name,last,year\njohn,doe,1986\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)

      input2 = "name,last,year\njohn,doe,1986\nmary,jane,1985\n"

      assert CSV.parse_string(input2, skip_headers: false) ==
               Nimble.parse_string(input2, skip_headers: false)
    end

    test "without trailing new line" do
      input = String.trim("name,last,year\njohn,doe,1986\nmary,jane,1985\n")

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end

    test "with CRLF terminations" do
      input = "name,last,year\r\njohn,doe,1986\r\n"

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end

    test "with empty string" do
      assert CSV.parse_string("", skip_headers: false) ==
               Nimble.parse_string("", skip_headers: false)

      input = "name\n\njohn\n\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)
    end

    test "with whitespace" do
      input = "name,last,year\n john , doe , 1986 \n"

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end

    test "with escape characters" do
      input1 = "name,last,year\njohn,\"doe\",1986\n"

      assert CSV.parse_string(input1, skip_headers: true) ==
               Nimble.parse_string(input1, skip_headers: true)

      input2 = "name,last,year\n\"john\",doe,\"1986\"\n"

      assert CSV.parse_string(input2, skip_headers: true) ==
               Nimble.parse_string(input2, skip_headers: true)

      input3 = "name,last,year\n\"john\",\"doe\",\"1986\"\nmary,\"jane\",1985\n"

      assert CSV.parse_string(input3, skip_headers: true) ==
               Nimble.parse_string(input3, skip_headers: true)

      input4 = "name,year\n\"doe, john\",1986\n\"jane, mary\",1985\n"

      assert CSV.parse_string(input4, skip_headers: true) ==
               Nimble.parse_string(input4, skip_headers: true)
    end

    test "with escape characters spanning multiple lines" do
      input =
        "name,last,comments\njohn,\"doe\",\"this is a\nreally long comment\nwith multiple lines\"\nmary,jane,short comment\n"

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end

    test "with escaped escape characters (double quotes)" do
      input =
        "name,last,comments\njohn,\"doe\",\"with \"\"double-quotes\"\" inside\"\nmary,jane,\"with , inside\"\n"

      assert CSV.parse_string(input, skip_headers: true) ==
               Nimble.parse_string(input, skip_headers: true)
    end
  end

  describe "parse_enumerable/2" do
    test "basic parsing" do
      lines = ["name,last,year\n", "john,doe,1986\n"]

      assert CSV.parse_enumerable(lines, skip_headers: true) ==
               Nimble.parse_enumerable(lines, skip_headers: true)

      assert CSV.parse_enumerable(lines, skip_headers: false) ==
               Nimble.parse_enumerable(lines, skip_headers: false)
    end
  end

  describe "parse_stream/2" do
    test "basic streaming" do
      lines = ["name,last,year\n", "john,doe,1986\n"]

      zig_stream = Stream.map(lines, &String.upcase/1)
      nimble_stream = Stream.map(lines, &String.upcase/1)

      assert CSV.parse_stream(zig_stream, skip_headers: true) |> Enum.to_list() ==
               Nimble.parse_stream(nimble_stream, skip_headers: true) |> Enum.to_list()

      zig_stream2 = Stream.map(lines, &String.upcase/1)
      nimble_stream2 = Stream.map(lines, &String.upcase/1)

      assert CSV.parse_stream(zig_stream2, skip_headers: false) |> Enum.to_list() ==
               Nimble.parse_stream(nimble_stream2, skip_headers: false) |> Enum.to_list()
    end
  end

  describe "dump_to_iodata/1" do
    test "basic dumping" do
      rows = [["name", "age"], ["john", 27]]

      assert IO.iodata_to_binary(CSV.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "dumping with newlines in fields" do
      rows = [["name", "age"], ["john\ndoe", 27]]

      assert IO.iodata_to_binary(CSV.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "dumping with quotes in fields" do
      rows = [["name", "age"], ["john \"nick\" doe", 27]]

      assert IO.iodata_to_binary(CSV.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end

    test "dumping with commas in fields" do
      rows = [["name", "age"], ["doe, john", 27]]

      assert IO.iodata_to_binary(CSV.dump_to_iodata(rows)) ==
               IO.iodata_to_binary(Nimble.dump_to_iodata(rows))
    end
  end

  describe "dump_to_stream/1" do
    test "basic streaming dump" do
      rows = [["name", "age"], ["john", 27]]

      assert IO.iodata_to_binary(Enum.to_list(CSV.dump_to_stream(rows))) ==
               IO.iodata_to_binary(Enum.to_list(Nimble.dump_to_stream(rows)))
    end

    test "streaming dump with special characters" do
      rows = [["name", "age"], ["john \"nick\" doe", 27]]

      assert IO.iodata_to_binary(Enum.to_list(CSV.dump_to_stream(rows))) ==
               IO.iodata_to_binary(Enum.to_list(Nimble.dump_to_stream(rows)))
    end
  end

  describe "to_line_stream/1" do
    test "converts arbitrary chunks to lines (with newlines preserved)" do
      stream = [
        "name,last,year\n",
        "john,doe,1986\n",
        "jane,",
        "doe,1987\n",
        "james,doe,1992\nryan,doe",
        ",1893"
      ]

      assert CSV.to_line_stream(stream) |> Enum.into([]) ==
               Nimble.to_line_stream(stream) |> Enum.into([])
    end
  end

  describe "round-trip" do
    test "parse then dump produces equivalent output" do
      original = [["name", "age"], ["john", "27"], ["mary", "32"]]

      zig_dumped = CSV.dump_to_iodata(original) |> IO.iodata_to_binary()
      nimble_dumped = Nimble.dump_to_iodata(original) |> IO.iodata_to_binary()
      assert zig_dumped == nimble_dumped

      zig_parsed = CSV.parse_string(zig_dumped, skip_headers: false)
      nimble_parsed = Nimble.parse_string(nimble_dumped, skip_headers: false)
      assert zig_parsed == nimble_parsed
      assert zig_parsed == original
    end

    test "round-trip with special characters" do
      original = [
        ["name", "comment"],
        ["john", "hello, world"],
        ["mary", "say \"hi\""],
        ["jane", "line1\nline2"]
      ]

      zig_dumped = CSV.dump_to_iodata(original) |> IO.iodata_to_binary()
      nimble_dumped = Nimble.dump_to_iodata(original) |> IO.iodata_to_binary()
      assert zig_dumped == nimble_dumped

      zig_parsed = CSV.parse_string(zig_dumped, skip_headers: false)
      nimble_parsed = Nimble.parse_string(nimble_dumped, skip_headers: false)
      assert zig_parsed == nimble_parsed
      assert zig_parsed == original
    end
  end

  describe "strategy selection" do
    test "all strategies produce identical output matching NimbleCSV" do
      csv =
        "name,age,comment\njohn,27,\"hello, world\"\nmary,32,\"say \"\"hi\"\"\"\njane,28,\"multi\nline\"\n"

      nimble_result = Nimble.parse_string(csv, skip_headers: false)
      basic = CSV.parse_string(csv, strategy: :basic, skip_headers: false)
      simd = CSV.parse_string(csv, strategy: :simd, skip_headers: false)
      parallel = CSV.parse_string(csv, strategy: :parallel, skip_headers: false)
      zero_copy = CSV.parse_string(csv, strategy: :zero_copy, skip_headers: false)

      assert basic == nimble_result
      assert simd == nimble_result
      assert parallel == nimble_result
      assert zero_copy == nimble_result
    end
  end

  describe "edge cases" do
    test "single field" do
      input = "a\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)
    end

    test "empty fields" do
      input1 = "a,,b\n"

      assert CSV.parse_string(input1, skip_headers: false) ==
               Nimble.parse_string(input1, skip_headers: false)

      input2 = ",a,\n"

      assert CSV.parse_string(input2, skip_headers: false) ==
               Nimble.parse_string(input2, skip_headers: false)
    end

    test "quoted empty field" do
      input = "\"\",a\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)
    end

    test "only whitespace in quoted field" do
      input = "\" \",a\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)
    end

    test "mixed line endings" do
      input = "a,b\nc,d\r\ne,f\n"

      assert CSV.parse_string(input, skip_headers: false) ==
               Nimble.parse_string(input, skip_headers: false)
    end
  end
end
