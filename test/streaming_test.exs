defmodule StreamingTest do
  @moduledoc """
  Tests for the streaming CSV parser (ZigCSV.Streaming).
  """
  use ExUnit.Case

  alias ZigCSV.RFC4180, as: CSV

  describe "parse_chunks/2" do
    test "basic chunked parsing" do
      chunks = ["a,b\n1,", "2\n3,4\n"]
      result = ZigCSV.Streaming.parse_chunks(chunks)
      assert result == [["a", "b"], ["1", "2"], ["3", "4"]]
    end

    test "empty chunks" do
      assert ZigCSV.Streaming.parse_chunks([]) == []
      assert ZigCSV.Streaming.parse_chunks([""]) == []
    end

    test "row split across chunks" do
      chunks = ["a,b\n1,", "2\n"]
      result = ZigCSV.Streaming.parse_chunks(chunks)
      assert result == [["a", "b"], ["1", "2"]]
    end

    test "quoted field split across chunks" do
      chunks = ["\"hel", "lo\",world\n"]
      result = ZigCSV.Streaming.parse_chunks(chunks)
      assert result == [["hello", "world"]]
    end
  end

  describe "stream_enumerable/2" do
    test "basic correctness" do
      chunks = ["name,age\njohn,27\n", "jane,30\n"]

      result =
        chunks
        |> ZigCSV.Streaming.stream_enumerable()
        |> Enum.to_list()

      assert result == [["name", "age"], ["john", "27"], ["jane", "30"]]
    end
  end

  describe "streaming buffer cap" do
    test "raises when buffer exceeds max_row_size" do
      # Create chunks that form an unterminated quoted field
      # With a tiny max_row_size, this should raise
      chunks = ["\"this is an unterminated quote that keeps going", " and going and going"]

      assert_raise ZigCSV.ParseError, ~r/max_row_size/, fn ->
        ZigCSV.Streaming.parse_chunks(chunks, max_row_size: 10)
      end
    end

    test "normal data within max_row_size succeeds" do
      chunks = ["a,b\n1,2\n"]
      result = ZigCSV.Streaming.parse_chunks(chunks, max_row_size: 1024)
      assert result == [["a", "b"], ["1", "2"]]
    end

    test "default max_row_size allows large rows" do
      # A 1MB row should be fine with the 16MB default
      big = String.duplicate("x", 1_000_000)
      chunks = ["#{big},b\n"]
      result = ZigCSV.Streaming.parse_chunks(chunks)
      assert length(result) == 1
    end

    test "stream_enumerable respects max_row_size" do
      chunks = ["\"unterminated field that is very long"]

      assert_raise ZigCSV.ParseError, ~r/max_row_size/, fn ->
        chunks
        |> ZigCSV.Streaming.stream_enumerable(max_row_size: 10)
        |> Enum.to_list()
      end
    end
  end

  describe "parse_stream/2" do
    test "header skipping" do
      chunks = ["name,age\njohn,27\njane,30\n"]

      result =
        chunks
        |> CSV.parse_stream(skip_headers: true)
        |> Enum.to_list()

      assert result == [["john", "27"], ["jane", "30"]]
    end

    test "no header skipping" do
      chunks = ["name,age\njohn,27\n"]

      result =
        chunks
        |> CSV.parse_stream(skip_headers: false)
        |> Enum.to_list()

      assert result == [["name", "age"], ["john", "27"]]
    end
  end
end
