# Define test parsers before the test module
ZigCSV.define(TestTSV,
  separator: "\t",
  escape: "\"",
  line_separator: "\n"
)

ZigCSV.define(TestPSV,
  separator: "|",
  escape: "\"",
  line_separator: "\n"
)

ZigCSV.define(TestSSV,
  separator: ";",
  escape: "\"",
  line_separator: "\n"
)

# Multi-separator parsers
ZigCSV.define(TestMultiSep,
  separator: [",", "|"],
  escape: "\"",
  line_separator: "\n"
)

ZigCSV.define(TestMultiByteSep,
  separator: "||",
  escape: "\"",
  line_separator: "\n"
)

ZigCSV.define(TestMixedSep,
  separator: [",", "||"],
  escape: "\"",
  line_separator: "\n"
)

ZigCSV.define(TestMultiByteEsc,
  separator: ",",
  escape: "''",
  line_separator: "\n"
)

defmodule ZigCSVTest do
  use ExUnit.Case

  alias ZigCSV.RFC4180, as: CSV

  describe "basic parsing" do
    test "parses simple CSV (skips headers by default)" do
      assert CSV.parse_string("a,b,c\n1,2,3\n") == [["1", "2", "3"]]
    end

    test "parses simple CSV with skip_headers: false" do
      assert CSV.parse_string("a,b,c\n1,2,3\n", skip_headers: false) ==
               [["a", "b", "c"], ["1", "2", "3"]]
    end

    test "parses with explicit skip_headers: true" do
      assert CSV.parse_string("a,b,c\n1,2,3\n", skip_headers: true) == [["1", "2", "3"]]
    end
  end

  describe "strategies" do
    test "all strategies produce identical output" do
      csv = "a,b,c\n1,2,3\n"
      expected = [["a", "b", "c"], ["1", "2", "3"]]

      assert CSV.parse_string(csv, strategy: :basic, skip_headers: false) == expected
      assert CSV.parse_string(csv, strategy: :simd, skip_headers: false) == expected
      assert CSV.parse_string(csv, strategy: :parallel, skip_headers: false) == expected
    end
  end

  describe "options/0" do
    test "returns module configuration" do
      opts = CSV.options()
      assert opts[:separator] == ","
      assert opts[:escape] == "\""
      assert opts[:strategy] == :simd
    end
  end

  describe "configurable separator" do
    test "TSV parsing with tab separator" do
      tsv = "name\tage\njohn\t27\njane\t30\n"
      result = TestTSV.parse_string(tsv, skip_headers: false)
      assert result == [["name", "age"], ["john", "27"], ["jane", "30"]]
    end

    test "TSV with all strategies" do
      tsv = "a\tb\nc\td\n"
      expected = [["a", "b"], ["c", "d"]]

      assert TestTSV.parse_string(tsv, strategy: :basic, skip_headers: false) == expected
      assert TestTSV.parse_string(tsv, strategy: :simd, skip_headers: false) == expected
      assert TestTSV.parse_string(tsv, strategy: :parallel, skip_headers: false) == expected
    end

    test "TSV with quoted fields containing tabs" do
      tsv = "a\t\"b\tc\"\td\n"
      result = TestTSV.parse_string(tsv, skip_headers: false)
      assert result == [["a", "b\tc", "d"]]
    end

    test "pipe-separated values" do
      psv = "a|b|c\n1|2|3\n"
      result = TestPSV.parse_string(psv, skip_headers: false)
      assert result == [["a", "b", "c"], ["1", "2", "3"]]
    end

    test "semicolon-separated values" do
      ssv = "a;b;c\n1;2;3\n"
      result = TestSSV.parse_string(ssv, skip_headers: false)
      assert result == [["a", "b", "c"], ["1", "2", "3"]]
    end
  end

  describe "multi-separator support" do
    test "comma and pipe separators" do
      input = "a,b|c\n1|2,3\n"
      result = TestMultiSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b", "c"], ["1", "2", "3"]]
    end

    test "multi-separator with quoted fields" do
      input = "a,\"b|c\"|d\n"
      result = TestMultiSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b|c", "d"]]
    end

    test "multi-separator with all strategies" do
      input = "a,b|c\n1|2,3\n"
      expected = [["a", "b", "c"], ["1", "2", "3"]]

      assert TestMultiSep.parse_string(input, strategy: :basic, skip_headers: false) == expected
      assert TestMultiSep.parse_string(input, strategy: :simd, skip_headers: false) == expected
      assert TestMultiSep.parse_string(input, strategy: :parallel, skip_headers: false) == expected
      assert TestMultiSep.parse_string(input, strategy: :zero_copy, skip_headers: false) == expected
    end

    test "multi-separator options returns original separator" do
      opts = TestMultiSep.options()
      assert opts[:separator] == [",", "|"]
    end
  end

  describe "multi-byte separator support" do
    test "double-pipe separator" do
      input = "a||b||c\n1||2||3\n"
      result = TestMultiByteSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b", "c"], ["1", "2", "3"]]
    end

    test "multi-byte separator with quoted fields" do
      input = "a||\"b||c\"||d\n"
      result = TestMultiByteSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b||c", "d"]]
    end

    test "multi-byte separator with all strategies" do
      input = "a||b||c\n1||2||3\n"
      expected = [["a", "b", "c"], ["1", "2", "3"]]

      assert TestMultiByteSep.parse_string(input, strategy: :basic, skip_headers: false) == expected
      assert TestMultiByteSep.parse_string(input, strategy: :simd, skip_headers: false) == expected
      assert TestMultiByteSep.parse_string(input, strategy: :parallel, skip_headers: false) == expected
      assert TestMultiByteSep.parse_string(input, strategy: :zero_copy, skip_headers: false) == expected
    end
  end

  describe "mixed single and multi-byte separators" do
    test "comma and double-pipe separators" do
      input = "a,b||c\n1||2,3\n"
      result = TestMixedSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b", "c"], ["1", "2", "3"]]
    end

    test "mixed separators with quoted fields" do
      input = "a,\"b||c\"||d\n"
      result = TestMixedSep.parse_string(input, skip_headers: false)
      assert result == [["a", "b||c", "d"]]
    end

    test "mixed separators with all strategies" do
      input = "a,b||c\n1||2,3\n"
      expected = [["a", "b", "c"], ["1", "2", "3"]]

      assert TestMixedSep.parse_string(input, strategy: :basic, skip_headers: false) == expected
      assert TestMixedSep.parse_string(input, strategy: :simd, skip_headers: false) == expected
      assert TestMixedSep.parse_string(input, strategy: :parallel, skip_headers: false) == expected
      assert TestMixedSep.parse_string(input, strategy: :zero_copy, skip_headers: false) == expected
    end
  end

  describe "multi-byte escape support" do
    test "double-single-quote escape" do
      input = "a,b,c\n''hello'',world,''foo''''bar''\n"
      result = TestMultiByteEsc.parse_string(input, skip_headers: false)
      assert result == [["a", "b", "c"], ["hello", "world", "foo''bar"]]
    end

    test "multi-byte escape with all strategies" do
      input = "a,''b'',c\n"
      expected = [["a", "b", "c"]]

      assert TestMultiByteEsc.parse_string(input, strategy: :basic, skip_headers: false) == expected
      assert TestMultiByteEsc.parse_string(input, strategy: :simd, skip_headers: false) == expected
      assert TestMultiByteEsc.parse_string(input, strategy: :parallel, skip_headers: false) == expected
      assert TestMultiByteEsc.parse_string(input, strategy: :zero_copy, skip_headers: false) == expected
    end
  end
end
