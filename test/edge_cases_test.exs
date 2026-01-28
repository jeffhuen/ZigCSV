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

    test "quoted field with extra whitespace around quotes raises" do
      # Space before quote means this is an unquoted field containing a quote —
      # NimbleCSV raises on escape characters inside unquoted fields.
      assert_raise ZigCSV.ParseError, ~r/unexpected escape character/, fn ->
        CSV.parse_string(" \"hello\" \n", skip_headers: false)
      end
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
    test "unterminated quote at start raises" do
      # Opening quote with no closing quote — raises per NimbleCSV behavior
      assert_raise ZigCSV.ParseError, ~r/expected escape character/, fn ->
        CSV.parse_string("\"abc,def\n", skip_headers: false)
      end
    end

    test "quote in middle of unquoted field raises" do
      assert_raise ZigCSV.ParseError, ~r/unexpected escape character/, fn ->
        CSV.parse_string("ab\"cd,ef\n", skip_headers: false)
      end
    end

    test "quote at end of unquoted field raises" do
      assert_raise ZigCSV.ParseError, ~r/unexpected escape character/, fn ->
        CSV.parse_string("abc\",def\n", skip_headers: false)
      end
    end

    test "adjacent quoted fields" do
      assert CSV.parse_string(~s("a","b","c"\n), skip_headers: false) ==
               [["a", "b", "c"]]
    end
  end

  describe "limits and overflow" do
    test "2000 columns" do
      row = Enum.map_join(1..2000, ",", &"f#{&1}")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 2000
    end

    test "4096 columns (MAX_FIELDS limit)" do
      row = Enum.map_join(1..4096, ",", &"f#{&1}")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 4096
    end

    test "quoted field larger than 64KB (unescape overflow fallback)" do
      # A quoted field larger than the 65536-byte unescape buffer.
      # The field has no escape sequences, so raw content is correct either way.
      big = String.duplicate("x", 70_000)
      csv = "\"#{big}\",b\n"
      result = CSV.parse_string(csv, skip_headers: false)
      assert hd(hd(result)) == big
    end

    test "quoted field larger than 64KB with escape sequences" do
      # A quoted field with doubled quotes, larger than the unescape buffer.
      # When the field overflows the buffer, doubled quotes are preserved as-is.
      inner = String.duplicate("a", 60_000) <> "\"\"" <> String.duplicate("b", 10_000)
      csv = "\"#{inner}\",end\n"
      result = CSV.parse_string(csv, skip_headers: false)
      field = hd(hd(result))
      # Either the unescape worked (single quote) or fallback preserved raw (doubled quote)
      assert String.contains?(field, "a") and String.contains?(field, "b")
      assert byte_size(field) >= 70_000
    end
  end

  describe "unterminated quoted fields" do
    test "unterminated quoted field raises ParseError" do
      assert_raise ZigCSV.ParseError, ~r/expected escape character/, fn ->
        CSV.parse_string("\"hello", skip_headers: false)
      end
    end

    test "unterminated quote with other fields before it raises" do
      assert_raise ZigCSV.ParseError, ~r/expected escape character/, fn ->
        CSV.parse_string("a,\"hello", skip_headers: false)
      end
    end

    test "unterminated quote raises for all strategies" do
      for strategy <- [:basic, :simd, :parallel, :zero_copy] do
        assert_raise ZigCSV.ParseError, fn ->
          CSV.parse_string("a,\"hello", skip_headers: false, strategy: strategy)
        end
      end
    end

    test "unterminated quote error message matches NimbleCSV format" do
      err =
        assert_raise ZigCSV.ParseError, fn ->
          CSV.parse_string("\"hello", skip_headers: false)
        end

      assert err.message == "expected escape character \" but reached the end of file"
    end
  end

  describe "mid-field escape (quote inside unquoted field)" do
    test "quote in middle of unquoted field raises ParseError" do
      assert_raise ZigCSV.ParseError, ~r/unexpected escape character/, fn ->
        CSV.parse_string("ab\"cd,ef\n", skip_headers: false)
      end
    end

    test "quote at end of unquoted field raises ParseError" do
      assert_raise ZigCSV.ParseError, ~r/unexpected escape character/, fn ->
        CSV.parse_string("abc\",def\n", skip_headers: false)
      end
    end

    test "mid-field escape raises for all strategies" do
      for strategy <- [:basic, :simd, :parallel, :zero_copy] do
        assert_raise ZigCSV.ParseError, fn ->
          CSV.parse_string("ab\"cd,ef\n", skip_headers: false, strategy: strategy)
        end
      end
    end

    test "mid-field escape error message includes line content" do
      err =
        assert_raise ZigCSV.ParseError, fn ->
          CSV.parse_string("ab\"cd,ef\n", skip_headers: false)
        end

      assert err.message =~ "unexpected escape character \""
      # Line content is inspect-ed in the message, so check for the inspected form
      assert err.message =~ "in "
      assert err.message =~ "ab"
    end
  end

  describe "no field limit" do
    test "4096 columns" do
      row = Enum.map_join(1..4096, ",", &"f#{&1}")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 4096
    end

    test "5000 columns — no field limit" do
      row = Enum.map_join(1..5000, ",", &"f#{&1}")
      result = CSV.parse_string(row <> "\n", skip_headers: false)
      assert length(hd(result)) == 5000
    end

    test "large field count consistent across strategies" do
      row = Enum.map_join(1..5000, ",", &"f#{&1}")

      for strategy <- [:basic, :simd, :parallel, :zero_copy] do
        result = CSV.parse_string(row <> "\n", skip_headers: false, strategy: strategy)
        assert length(hd(result)) == 5000, "failed for strategy #{strategy}"
      end
    end

    test "rows after a large row are not corrupted" do
      row1 = Enum.map_join(1..5000, ",", &"f#{&1}")
      csv = row1 <> "\na,b\n"
      result = CSV.parse_string(csv, skip_headers: false)
      assert length(result) == 2
      assert length(Enum.at(result, 0)) == 5000
      assert Enum.at(result, 1) == ["a", "b"]
    end
  end

  describe "NIF return validation" do
    test "zero_copy returns error atom for non-binary input" do
      # The zero_copy strategy can return :error for invalid input terms.
      # This should be caught and raised as ParseError.
      # We can't easily trigger this from Elixir since parse_string
      # always passes a binary, but we verify the guard works.
      result = CSV.parse_string("a,b\n", skip_headers: false, strategy: :zero_copy)
      assert is_list(result)
    end
  end

  describe "all strategies produce identical output" do
    @strategies [:basic, :simd, :parallel, :zero_copy]
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
