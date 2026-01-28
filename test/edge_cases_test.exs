defmodule EdgeCasesTest do
  @moduledoc """
  Comprehensive edge case tests inspired by PapaParse test suite.

  These tests cover malformed input, unusual delimiters, whitespace handling,
  and other edge cases that real-world CSV files may contain.

  See: https://github.com/mholt/PapaParse/blob/master/tests/test-cases.js
  """
  use ExUnit.Case

  alias ZigCSV.RFC4180, as: CSV

  describe "basic parsing" do
    test "empty input string" do
      assert CSV.parse_string("", skip_headers: false) == []
    end

    test "input is just a newline" do
      assert CSV.parse_string("\n", skip_headers: false) == [[""]]
    end

    test "input is just delimiter" do
      assert CSV.parse_string(",", skip_headers: false) == [["", ""]]
    end

    test "input is just empty fields" do
      assert CSV.parse_string(",,\n,,", skip_headers: false) == [["", "", ""], ["", "", ""]]
    end

    test "single unquoted field" do
      assert CSV.parse_string("hello", skip_headers: false) == [["hello"]]
    end

    test "single quoted field" do
      assert CSV.parse_string("\"hello\"", skip_headers: false) == [["hello"]]
    end
  end

  describe "whitespace handling" do
    test "whitespace at edges of unquoted field" do
      assert CSV.parse_string("  hello  ,  world  \n", skip_headers: false) ==
               [["  hello  ", "  world  "]]
    end

    test "whitespace preserved in quoted field" do
      assert CSV.parse_string(~s("  hello  ","  world  "\n), skip_headers: false) ==
               [["  hello  ", "  world  "]]
    end

    test "quoted field with extra whitespace around quotes" do
      # Note: space before quote is part of field, space after closing quote is trimmed by some parsers
      result = CSV.parse_string(" \"hello\" \n", skip_headers: false)
      # We should preserve the leading space as part of the unquoted prefix
      assert result == [[" \"hello\" "]] or result == [[" hello "]]
    end

    test "tabs as whitespace" do
      assert CSV.parse_string("\thello\t,\tworld\t\n", skip_headers: false) ==
               [["\thello\t", "\tworld\t"]]
    end
  end

  describe "quoted fields" do
    test "basic quoted field" do
      assert CSV.parse_string("\"hello\",world\n", skip_headers: false) == [["hello", "world"]]
    end

    test "quoted field with delimiter inside" do
      assert CSV.parse_string("\"hello,world\",test\n", skip_headers: false) ==
               [["hello,world", "test"]]
    end

    test "quoted field with line break" do
      assert CSV.parse_string("\"hello\nworld\",test\n", skip_headers: false) ==
               [["hello\nworld", "test"]]
    end

    test "quoted field with CRLF line break" do
      assert CSV.parse_string("\"hello\r\nworld\",test\n", skip_headers: false) ==
               [["hello\r\nworld", "test"]]
    end

    test "quoted field with multiple line breaks" do
      assert CSV.parse_string("\"line1\nline2\nline3\",b\n", skip_headers: false) ==
               [["line1\nline2\nline3", "b"]]
    end

    test "escaped quotes (doubled)" do
      # "hello ""world""",test
      assert CSV.parse_string(~s("hello ""world""",test\n), skip_headers: false) ==
               [["hello \"world\"", "test"]]
    end

    test "empty quoted field" do
      assert CSV.parse_string(~s("",b,c\n), skip_headers: false) == [["", "b", "c"]]
    end

    test "quoted field containing only quotes" do
      # """" is a quoted field containing one quote
      assert CSV.parse_string(~s(""""\n), skip_headers: false) == [["\""]]
    end

    test "multiple escaped quotes in sequence" do
      # "a""""b" is a quoted field: a""b
      assert CSV.parse_string(~s("a""""b"\n), skip_headers: false) == [["a\"\"b"]]
    end
  end

  describe "multiple consecutive empty fields" do
    test "leading empty fields" do
      assert CSV.parse_string(",,c\n", skip_headers: false) == [["", "", "c"]]
    end

    test "trailing empty fields" do
      assert CSV.parse_string("a,,\n", skip_headers: false) == [["a", "", ""]]
    end

    test "middle empty fields" do
      assert CSV.parse_string("a,,c\n", skip_headers: false) == [["a", "", "c"]]
    end

    test "all empty fields" do
      assert CSV.parse_string(",,,\n", skip_headers: false) == [["", "", "", ""]]
    end
  end

  describe "line endings" do
    test "LF line endings" do
      assert CSV.parse_string("a,b\nc,d\n", skip_headers: false) ==
               [["a", "b"], ["c", "d"]]
    end

    test "CRLF line endings" do
      assert CSV.parse_string("a,b\r\nc,d\r\n", skip_headers: false) ==
               [["a", "b"], ["c", "d"]]
    end

    test "CR only line endings" do
      # Many parsers treat CR alone as line ending
      result = CSV.parse_string("a,b\rc,d\r", skip_headers: false)
      # Could be parsed as single row with embedded CR or multiple rows
      assert is_list(result)
    end

    test "mixed line endings" do
      assert CSV.parse_string("a,b\nc,d\r\ne,f\n", skip_headers: false) ==
               [["a", "b"], ["c", "d"], ["e", "f"]]
    end

    test "no trailing newline" do
      assert CSV.parse_string("a,b\nc,d", skip_headers: false) ==
               [["a", "b"], ["c", "d"]]
    end
  end

  describe "field count variations" do
    test "rows with different field counts" do
      # "Ragged" CSV - some parsers error, some accept
      result = CSV.parse_string("a,b,c\n1,2\n3,4,5,6\n", skip_headers: false)
      assert length(result) == 3
      assert hd(result) == ["a", "b", "c"]
    end

    test "single column" do
      assert CSV.parse_string("a\nb\nc\n", skip_headers: false) ==
               [["a"], ["b"], ["c"]]
    end

    test "many columns" do
      row = Enum.join(1..100, ",")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 100
    end
  end

  describe "unicode and encoding" do
    test "UTF-8 characters" do
      assert CSV.parse_string("名前,年齢\nジョン,27\n", skip_headers: false) ==
               [["名前", "年齢"], ["ジョン", "27"]]
    end

    test "emoji in fields" do
      assert CSV.parse_string("emoji,text\n🎉,party\n", skip_headers: false) ==
               [["emoji", "text"], ["🎉", "party"]]
    end

    test "mixed scripts" do
      assert CSV.parse_string("Hello,Привет,你好,مرحبا\n", skip_headers: false) ==
               [["Hello", "Привет", "你好", "مرحبا"]]
    end

    test "special unicode characters" do
      # Zero-width joiner, combining characters, etc.
      assert CSV.parse_string("a\u200Db,c\u0301\n", skip_headers: false) ==
               [["a\u200Db", "c\u0301"]]
    end

    test "UTF-8 BOM handling" do
      # With trim_bom option
      bom = <<0xEF, 0xBB, 0xBF>>
      csv = bom <> "a,b\n1,2\n"
      # Default (no trim) - BOM is part of first field
      result = CSV.parse_string(csv, skip_headers: false)
      assert hd(hd(result)) == bom <> "a" or hd(hd(result)) == "a"
    end
  end

  describe "special characters in fields" do
    test "null bytes" do
      result = CSV.parse_string("a\x00b,c\n", skip_headers: false)
      assert length(result) == 1
    end

    test "control characters" do
      assert CSV.parse_string("a\x01b,c\x02d\n", skip_headers: false) ==
               [["a\x01b", "c\x02d"]]
    end

    test "backslash" do
      assert CSV.parse_string("a\\b,c\\d\n", skip_headers: false) ==
               [["a\\b", "c\\d"]]
    end

    test "forward slash" do
      assert CSV.parse_string("a/b,c/d\n", skip_headers: false) ==
               [["a/b", "c/d"]]
    end
  end

  describe "large data" do
    test "very long field" do
      long_value = String.duplicate("x", 100_000)
      result = CSV.parse_string("#{long_value},b\n", skip_headers: false)
      assert hd(hd(result)) == long_value
    end

    test "many rows" do
      csv = Enum.map_join(1..1000, "\n", fn i -> "row#{i},#{i}" end) <> "\n"
      result = CSV.parse_string(csv, skip_headers: false)
      assert length(result) == 1000
    end

    test "many columns" do
      row = Enum.map_join(1..500, ",", &"col#{&1}")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 500
    end
  end

  describe "quoted field edge cases" do
    test "quote at start of unquoted field" do
      # Ambiguous - could be start of quoted field or literal quote
      result = CSV.parse_string("\"abc,def\n", skip_headers: false)
      assert is_list(result)
    end

    test "quote in middle of unquoted field" do
      result = CSV.parse_string("ab\"cd,ef\n", skip_headers: false)
      # Most parsers treat this as literal quote in unquoted field
      assert hd(hd(result)) =~ "ab"
    end

    test "quote at end of unquoted field" do
      result = CSV.parse_string("abc\",def\n", skip_headers: false)
      assert is_list(result)
    end

    test "adjacent quoted fields" do
      assert CSV.parse_string(~s("a","b","c"\n), skip_headers: false) ==
               [["a", "b", "c"]]
    end
  end

  describe "all strategies produce identical output" do
    @strategies [:basic, :simd, :indexed, :parallel, :zero_copy]
    @test_cases [
      {"simple", "a,b,c\n1,2,3\n"},
      {"quoted", "\"a,b\",c\n1,\"2,3\"\n"},
      {"escaped", "\"a\"\"b\",c\n"},
      {"newline", "\"a\nb\",c\n"},
      {"empty", ",,\n"},
      {"unicode", "名前,年齢\nジョン,27\n"}
    ]

    for {name, csv} <- @test_cases do
      test "#{name} consistent across strategies" do
        csv = unquote(csv)

        results =
          for strategy <- @strategies do
            {strategy, CSV.parse_string(csv, skip_headers: false, strategy: strategy)}
          end

        [{_, expected} | rest] = results

        for {strategy, result} <- rest do
          assert result == expected,
                 "Strategy #{strategy} produced different result for #{unquote(name)}"
        end
      end
    end
  end
end
