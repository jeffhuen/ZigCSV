defmodule NifRobustnessTest do
  @moduledoc """
  Tests for NIF robustness: concurrent access, memory pressure, and scheduler behavior.

  These tests verify that ZigCSV NIFs behave correctly under concurrent load
  and don't leak memory or block the BEAM scheduler.
  """
  use ExUnit.Case, async: true

  alias ZigCSV.RFC4180, as: CSV

  # ==========================================================================
  # Concurrent Parse Access
  # ==========================================================================

  describe "concurrent parse_string" do
    test "many processes parsing simultaneously produce correct results" do
      csv = "name,age\nalice,30\nbob,25\n"
      expected = [["alice", "30"], ["bob", "25"]]

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            CSV.parse_string(csv)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for result <- results do
        assert result == expected
      end
    end

    test "concurrent parsing with all strategies" do
      csv = "a,b,c\n1,2,3\n4,5,6\n"
      expected = [["1", "2", "3"], ["4", "5", "6"]]

      tasks =
        for strategy <- [:basic, :simd, :parallel, :zero_copy],
            _ <- 1..25 do
          Task.async(fn ->
            {strategy, CSV.parse_string(csv, strategy: strategy)}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for {strategy, result} <- results do
        assert result == expected,
               "Strategy #{strategy} produced unexpected result: #{inspect(result)}"
      end
    end

    test "concurrent parsing with varied input sizes" do
      inputs =
        for n <- [1, 10, 100, 1_000] do
          rows = for i <- 1..n, do: "field_#{i},value_#{i}\n"
          {n, "header1,header2\n" <> Enum.join(rows)}
        end

      tasks =
        for {n, csv} <- inputs,
            _ <- 1..10 do
          Task.async(fn ->
            result = CSV.parse_string(csv)
            {n, length(result)}
          end)
        end

      results = Task.await_many(tasks, 30_000)

      for {expected_count, actual_count} <- results do
        assert actual_count == expected_count
      end
    end
  end

  # ==========================================================================
  # Concurrent Streaming
  # ==========================================================================

  describe "concurrent streaming" do
    test "multiple streams consuming simultaneously" do
      csv = "h1,h2\n" <> String.duplicate("a,b\n", 100)

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            [csv]
            |> CSV.parse_stream()
            |> Enum.to_list()
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for result <- results do
        assert length(result) == 100
        assert Enum.all?(result, fn row -> row == ["a", "b"] end)
      end
    end
  end

  # ==========================================================================
  # Memory Stability
  # ==========================================================================

  describe "memory stability" do
    test "repeated parsing does not leak memory" do
      csv = "a,b,c\n" <> String.duplicate("hello,world,test\n", 1_000)

      # Warm up
      for _ <- 1..5, do: CSV.parse_string(csv)
      :erlang.garbage_collect()
      Process.sleep(100)

      mem_before = :erlang.memory(:total)

      # Parse many times
      for _ <- 1..100 do
        CSV.parse_string(csv)
      end

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_after = :erlang.memory(:total)

      # Allow up to 2MB growth (GC timing, process overhead).
      # The key assertion: we shouldn't see unbounded growth.
      growth = mem_after - mem_before
      assert growth < 2_000_000, "Memory grew by #{growth} bytes after 100 parse cycles"
    end

    test "streaming parser does not leak across many iterations" do
      chunks = ["h1,h2\n", "a,b\n", "c,d\n"]

      # Warm up
      for _ <- 1..5, do: ZigCSV.Streaming.parse_chunks(chunks)
      :erlang.garbage_collect()
      Process.sleep(100)

      mem_before = :erlang.memory(:total)

      for _ <- 1..200 do
        ZigCSV.Streaming.parse_chunks(chunks)
      end

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before
      assert growth < 2_000_000, "Memory grew by #{growth} bytes after 200 streaming cycles"
    end
  end

  # ==========================================================================
  # Scheduler Non-Blocking
  # ==========================================================================

  describe "scheduler behavior" do
    test "parsing does not block other processes" do
      # Start a large parse in a separate process
      large_csv = "h1,h2\n" <> String.duplicate("hello,world\n", 50_000)

      parser = Task.async(fn -> CSV.parse_string(large_csv) end)

      # Meanwhile, a simple operation should complete promptly
      {time_us, _} = :timer.tc(fn -> 1 + 1 end)

      # Simple arithmetic should complete in under 1ms even during parsing.
      # With dirty_cpu scheduling, the parse NIF won't block the normal scheduler.
      assert time_us < 1_000, "Simple operation took #{time_us}μs — scheduler may be blocked"

      result = Task.await(parser, 30_000)
      assert length(result) == 50_000
    end

    test "many concurrent parses don't starve the scheduler" do
      csv = "a,b\n" <> String.duplicate("x,y\n", 10_000)

      # Launch 10 concurrent heavy parses
      parsers =
        for _ <- 1..10 do
          Task.async(fn -> CSV.parse_string(csv) end)
        end

      # A lightweight process should still be responsive
      pinger =
        Task.async(fn ->
          for _ <- 1..10 do
            {time_us, _} = :timer.tc(fn -> :erlang.system_time(:microsecond) end)
            time_us
          end
        end)

      ping_times = Task.await(pinger, 30_000)
      results = Task.await_many(parsers, 30_000)

      # All parses should succeed
      for result <- results do
        assert length(result) == 10_000
      end

      # All pings should be fast (< 10ms each)
      for time <- ping_times do
        assert time < 10_000, "Ping took #{time}μs — scheduler contention detected"
      end
    end
  end
end
