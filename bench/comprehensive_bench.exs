# Comprehensive CSV Benchmark: ZigCSV Strategies vs NimbleCSV
#
# Usage:
#   mix run bench/comprehensive_bench.exs
#
# Note: Memory tracking stubs currently return 0. Full tracking coming in future release.
#
# Strategies benchmarked:
#   :basic     - Byte-by-byte parsing (reference implementation)
#   :simd      - SIMD-accelerated via Zig @Vector (default)
#   :indexed   - Two-phase index-then-extract
#   :parallel  - Multi-threaded (dirty CPU scheduler)
#   :zero_copy - Sub-binary references (NimbleCSV-like memory model)
#   :streaming - Bounded-memory streaming (via parse_stream)

alias ZigCSV.RFC4180, as: CSV
alias NimbleCSV.RFC4180, as: NimbleCSV

defmodule ComprehensiveBench do
  @strategies [:basic, :simd, :parallel, :zero_copy]
  @output_dir "bench/results"

  def run do
    File.mkdir_p!(@output_dir)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.slice(0..14)

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("COMPREHENSIVE CSV BENCHMARK")
    IO.puts("Timestamp: #{timestamp}")
    IO.puts("Strategies: #{inspect(@strategies)}")
    IO.puts(String.duplicate("=", 70))

    # System info
    print_system_info()

    # Check memory tracking
    check_memory_tracking()

    # Generate test files
    test_files = generate_test_files()

    # Run benchmarks
    results = []

    # 1. Simple CSV (no quotes, no special chars)
    results = results ++ run_benchmark("Simple CSV", test_files.simple)

    # 2. Quoted CSV (fields with quotes, commas, newlines)
    results = results ++ run_benchmark("Quoted CSV", test_files.quoted)

    # 3. Mixed CSV (realistic - some quoted, some not)
    results = results ++ run_benchmark("Mixed CSV (Realistic)", test_files.mixed)

    # 4. Large file benchmark (~7MB)
    results = results ++ run_benchmark("Large File (7MB)", test_files.large)

    # 5. Very large file benchmark (~100MB) - demonstrates :parallel crossover
    results = results ++ run_parallel_crossover_benchmark("Very Large File (100MB)", test_files.very_large)

    # 6. Streaming benchmark (fair comparison)
    run_streaming_benchmark(test_files.large_path)

    # 7. Memory comparison (with honest metrics)
    run_memory_comparison(test_files.mixed)

    # 8. Correctness verification
    verify_all_strategies(test_files.mixed)

    # Save results
    save_results(timestamp, results)

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("BENCHMARK COMPLETE")
    IO.puts("Results saved to: #{@output_dir}/")
    IO.puts(String.duplicate("=", 70))
  end

  defp print_system_info do
    IO.puts("\n--- System Information ---")
    IO.puts("Elixir: #{System.version()}")
    IO.puts("OTP: #{System.otp_release()}")
    IO.puts("OS: #{:os.type() |> inspect()}")
    IO.puts("Schedulers: #{System.schedulers_online()}")
    IO.puts("ZigCSV: #{Application.spec(:zig_csv, :vsn)}")
    IO.puts("NimbleCSV: #{Application.spec(:nimble_csv, :vsn)}")
  end

  defp check_memory_tracking do
    IO.puts("\n--- Memory Tracking ---")
    ZigCSV.Native.reset_zig_memory_stats()
    # Do a small allocation
    _ = CSV.parse_string("a,b\n1,2\n", skip_headers: false)
    peak = ZigCSV.Native.get_zig_memory_peak()

    if peak > 0 do
      IO.puts("Status: ENABLED (memory_tracking feature active)")
    else
      IO.puts("Status: DISABLED (returns 0 - enable memory_tracking feature for detailed stats)")
    end
  end

  defp generate_test_files do
    IO.puts("\n--- Generating Test Files ---")

    # Simple CSV (10K rows, no quotes)
    simple = generate_simple_csv(10_000)
    IO.puts("Simple CSV: #{format_size(byte_size(simple))} (10K rows)")

    # Quoted CSV (10K rows, all fields quoted, some with special chars)
    quoted = generate_quoted_csv(10_000)
    IO.puts("Quoted CSV: #{format_size(byte_size(quoted))} (10K rows)")

    # Mixed/realistic CSV (10K rows)
    mixed = generate_mixed_csv(10_000)
    IO.puts("Mixed CSV: #{format_size(byte_size(mixed))} (10K rows)")

    # Large file (100K rows, ~7MB)
    large_path = "bench/data/large_bench.csv"
    large = ensure_large_file(large_path, 100_000)
    IO.puts("Large CSV: #{format_size(byte_size(large))} (100K rows)")

    # Very large file (1.5M rows, ~100MB) - for parallel strategy crossover
    very_large_path = "bench/data/very_large_bench.csv"
    very_large = ensure_large_file(very_large_path, 1_500_000)
    IO.puts("Very Large CSV: #{format_size(byte_size(very_large))} (1.5M rows)")

    %{
      simple: simple,
      quoted: quoted,
      mixed: mixed,
      large: large,
      large_path: large_path,
      very_large: very_large,
      very_large_path: very_large_path
    }
  end

  defp run_benchmark(name, csv) do
    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Benchmark: #{name}")
    IO.puts("Size: #{format_size(byte_size(csv))}")
    IO.puts(String.duplicate("-", 50))

    # Warm up
    for strategy <- @strategies do
      _ = CSV.parse_string(csv, strategy: strategy)
    end
    _ = NimbleCSV.parse_string(csv)

    # Build benchmark map
    benchmarks =
      @strategies
      |> Enum.map(fn strategy ->
        {"ZigCSV (#{strategy})", fn -> CSV.parse_string(csv, strategy: strategy) end}
      end)
      |> Map.new()
      |> Map.put("NimbleCSV", fn -> NimbleCSV.parse_string(csv) end)

    Benchee.run(
      benchmarks,
      warmup: 1,
      time: 3,
      memory_time: 1,
      print: [configuration: false],
      formatters: [
        Benchee.Formatters.Console
      ]
    )

    [{name, byte_size(csv)}]
  end

  # Benchmark specifically for :parallel strategy on very large files
  defp run_parallel_crossover_benchmark(name, csv) do
    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Benchmark: #{name}")
    IO.puts("Size: #{format_size(byte_size(csv))}")
    IO.puts("Purpose: Demonstrate :parallel strategy crossover point")
    IO.puts(String.duplicate("-", 50))

    # Only compare strategies relevant to large files
    strategies_to_test = [:simd, :zero_copy, :parallel]

    # Warm up
    for strategy <- strategies_to_test do
      _ = CSV.parse_string(csv, strategy: strategy)
    end
    _ = NimbleCSV.parse_string(csv)

    # Build benchmark map
    benchmarks =
      strategies_to_test
      |> Enum.map(fn strategy ->
        {"ZigCSV (#{strategy})", fn -> CSV.parse_string(csv, strategy: strategy) end}
      end)
      |> Map.new()
      |> Map.put("NimbleCSV", fn -> NimbleCSV.parse_string(csv) end)

    Benchee.run(
      benchmarks,
      warmup: 1,
      time: 5,  # Longer time for more stable results on large files
      memory_time: 1,
      print: [configuration: false],
      formatters: [
        Benchee.Formatters.Console
      ]
    )

    [{name, byte_size(csv)}]
  end

  defp run_streaming_benchmark(path) do
    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Benchmark: Streaming (Bounded Memory)")
    IO.puts("File: #{path}")
    IO.puts(String.duplicate("-", 50))

    # Get expected row count
    expected_rows = path |> File.read!() |> String.split("\n", trim: true) |> length() |> Kernel.-(1)
    IO.puts("Expected rows (excluding header): #{format_number(expected_rows)}")

    # ZigCSV streaming with binary chunks (unique capability)
    IO.puts("\n1. ZigCSV streaming (64KB binary chunks):")
    IO.puts("   Note: ZigCSV can handle arbitrary binary chunks")
    {zig_chunk_time, zig_chunk_count} = :timer.tc(fn ->
      path
      |> File.stream!([], 64 * 1024)
      |> CSV.parse_stream()
      |> Enum.count()
    end)
    IO.puts("   Rows: #{format_number(zig_chunk_count)}")
    IO.puts("   Time: #{format_time(zig_chunk_time)}")
    IO.puts("   Correct: #{zig_chunk_count == expected_rows}")

    # ZigCSV streaming with line-based input (for fair comparison)
    IO.puts("\n2. ZigCSV streaming (line-based):")
    {zig_line_time, zig_line_count} = :timer.tc(fn ->
      path
      |> File.stream!()  # Line-based (default)
      |> CSV.parse_stream()
      |> Enum.count()
    end)
    IO.puts("   Rows: #{format_number(zig_line_count)}")
    IO.puts("   Time: #{format_time(zig_line_time)}")
    IO.puts("   Correct: #{zig_line_count == expected_rows}")

    # NimbleCSV streaming (MUST use line-based input)
    IO.puts("\n3. NimbleCSV streaming (line-based - required):")
    IO.puts("   Note: NimbleCSV requires line-based streams")
    {nimble_time, nimble_count} = :timer.tc(fn ->
      path
      |> File.stream!()  # Line-based (required for NimbleCSV)
      |> NimbleCSV.parse_stream()
      |> Enum.count()
    end)
    IO.puts("   Rows: #{format_number(nimble_count)}")
    IO.puts("   Time: #{format_time(nimble_time)}")
    IO.puts("   Correct: #{nimble_count == expected_rows}")

    # Fair comparison (both line-based)
    IO.puts("\n--- Fair Comparison (both line-based) ---")
    speedup = nimble_time / zig_line_time
    IO.puts("ZigCSV vs NimbleCSV: #{Float.round(speedup, 2)}x faster")

    # Highlight ZigCSV's unique capability
    IO.puts("\n--- ZigCSV Unique Capability ---")
    IO.puts("ZigCSV can process binary chunks (useful for network streams, etc.)")
    IO.puts("Binary chunk throughput: #{format_size(trunc(byte_size(File.read!(path)) / (zig_chunk_time / 1_000_000)))}/sec")
  end

  defp run_memory_comparison(csv) do
    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Memory Comparison (HONEST METRICS)")
    IO.puts("CSV Size: #{format_size(byte_size(csv))}")
    IO.puts(String.duplicate("-", 50))

    IO.puts("\n=== IMPORTANT: Memory Measurement Methodology ===")
    IO.puts("- 'Process Heap': Memory delta in the calling process (excludes refc binaries)")
    IO.puts("- 'Total Retained': Actual RAM used by the parsed result (heap + binary refs)")
    IO.puts("- 'Zig NIF': Peak allocation on the Zig/NIF side during parsing")
    IO.puts("- NimbleCSV allocates entirely on BEAM; ZigCSV allocates on both sides")

    # Process heap memory (what Benchee measures - can be misleading!)
    IO.puts("\n1. Process Heap Memory (Benchee-style, excludes binaries):")
    IO.puts("   WARNING: This metric is misleading for sub-binary strategies!")
    for strategy <- @strategies do
      mem = measure_process_heap(fn -> CSV.parse_string(csv, strategy: strategy) end)
      IO.puts("   ZigCSV (#{strategy}): #{format_size(mem)}")
    end
    nimble_heap = measure_process_heap(fn -> NimbleCSV.parse_string(csv) end)
    IO.puts("   NimbleCSV: #{format_size(nimble_heap)}")

    # Total retained memory (honest measurement)
    IO.puts("\n2. Total Retained Memory (heap + binary refs - HONEST):")
    for strategy <- @strategies do
      mem = measure_total_retained(fn -> CSV.parse_string(csv, strategy: strategy) end)
      IO.puts("   ZigCSV (#{strategy}): #{format_size(mem)}")
    end
    nimble_total = measure_total_retained(fn -> NimbleCSV.parse_string(csv) end)
    IO.puts("   NimbleCSV: #{format_size(nimble_total)}")

    # Zig memory (if tracking enabled)
    peak = ZigCSV.Native.get_zig_memory_peak()
    if peak > 0 do
      IO.puts("\n3. Zig NIF Memory (peak allocation during parsing):")
      zig_mems = for strategy <- @strategies do
        ZigCSV.Native.reset_zig_memory_stats()
        _ = CSV.parse_string(csv, strategy: strategy)
        zig_peak = ZigCSV.Native.get_zig_memory_peak()
        IO.puts("   ZigCSV (#{strategy}): #{format_size(zig_peak)}")
        {strategy, zig_peak}
      end

      # Calculate true total (BEAM retained + Zig peak)
      IO.puts("\n4. True Total Memory (BEAM retained + Zig NIF):")
      for {strategy, zig_mem} <- zig_mems do
        beam_mem = measure_total_retained(fn -> CSV.parse_string(csv, strategy: strategy) end)
        total = beam_mem + zig_mem
        IO.puts("   ZigCSV (#{strategy}): #{format_size(total)} (#{format_size(beam_mem)} BEAM + #{format_size(zig_mem)} Zig)")
      end
      IO.puts("   NimbleCSV: #{format_size(nimble_total)} (all BEAM)")
    end

    # BEAM reductions
    IO.puts("\n5. BEAM Reductions (scheduler work):")
    IO.puts("   Note: Low reductions = less scheduler overhead, but NIFs can't be preempted")
    for strategy <- @strategies do
      reds = measure_reductions(fn -> CSV.parse_string(csv, strategy: strategy) end)
      IO.puts("   ZigCSV (#{strategy}): #{format_number(reds)}")
    end
    nimble_reds = measure_reductions(fn -> NimbleCSV.parse_string(csv) end)
    IO.puts("   NimbleCSV: #{format_number(nimble_reds)}")
  end

  defp verify_all_strategies(csv) do
    IO.puts("\n" <> String.duplicate("-", 50))
    IO.puts("Correctness Verification")
    IO.puts(String.duplicate("-", 50))

    results = for strategy <- @strategies, into: %{} do
      {strategy, CSV.parse_string(csv, strategy: strategy)}
    end
    nimble_result = NimbleCSV.parse_string(csv)

    # Check all ZigCSV strategies match each other
    reference = results[:simd]
    all_match = Enum.all?(@strategies, fn s -> results[s] == reference end)

    # Check ZigCSV matches NimbleCSV
    matches_nimble = reference == nimble_result

    IO.puts("All ZigCSV strategies identical: #{all_match}")
    IO.puts("ZigCSV matches NimbleCSV: #{matches_nimble}")
    IO.puts("Row count: #{length(reference)}")

    unless all_match do
      IO.puts("\nWARNING: Strategy mismatch detected!")
      for strategy <- @strategies do
        IO.puts("  #{strategy}: #{length(results[strategy])} rows")
      end
    end

    unless matches_nimble do
      IO.puts("\nWARNING: ZigCSV differs from NimbleCSV!")
      IO.puts("  ZigCSV: #{length(reference)} rows")
      IO.puts("  NimbleCSV: #{length(nimble_result)} rows")
    end
  end

  defp save_results(timestamp, _results) do
    # Save a summary markdown file
    summary = """
    # Benchmark Results - #{timestamp}

    ## System
    - Elixir: #{System.version()}
    - OTP: #{System.otp_release()}
    - Schedulers: #{System.schedulers_online()}

    ## Strategies Tested
    #{Enum.map(@strategies, &"- `:#{&1}`") |> Enum.join("\n")}
    - NimbleCSV (reference)

    ## Notes
    Results printed to console. For detailed analysis, re-run with:
    ```
    mix run bench/comprehensive_bench.exs 2>&1 | tee bench/results/#{timestamp}.txt
    ```
    """

    File.write!("#{@output_dir}/#{timestamp}_summary.md", summary)
  end

  # --- Test Data Generation ---

  defp generate_simple_csv(rows) do
    header = "id,name,value,category,timestamp\n"
    data =
      1..rows
      |> Enum.map(fn i ->
        "#{i},user#{i},#{:rand.uniform(1000)},cat#{rem(i, 5)},2024-01-#{rem(i, 28) + 1}"
      end)
      |> Enum.join("\n")
    header <> data <> "\n"
  end

  defp generate_quoted_csv(rows) do
    header = ~s("id","name","description","amount","notes"\n)
    data =
      1..rows
      |> Enum.map(fn i ->
        # RFC 4180: escape quotes by doubling them
        desc = ~s(Description with ""quotes"" and, commas for row #{i})
        notes = if rem(i, 10) == 0, do: "Line 1\nLine 2", else: "Normal notes"
        ~s("#{i}","User #{i}","#{desc}","#{:rand.uniform(1000)}","#{notes}")
      end)
      |> Enum.join("\n")
    header <> data <> "\n"
  end

  defp generate_mixed_csv(rows) do
    header = "id,name,email,amount,description,status\n"
    data =
      1..rows
      |> Enum.map(fn i ->
        # Mix of quoted and unquoted fields (RFC 4180 compliant)
        name = if rem(i, 3) == 0, do: ~s("User, Jr. #{i}"), else: "User#{i}"
        # RFC 4180: escape quotes by doubling them
        desc = if rem(i, 5) == 0, do: ~s("Has ""quotes"" inside"), else: "Simple desc"
        amount = :rand.uniform() * 1000 |> Float.round(2)
        status = Enum.random(["active", "pending", "done"])
        "#{i},#{name},user#{i}@example.com,#{amount},#{desc},#{status}"
      end)
      |> Enum.join("\n")
    header <> data <> "\n"
  end

  defp ensure_large_file(path, rows) do
    if File.exists?(path) do
      File.read!(path)
    else
      File.mkdir_p!(Path.dirname(path))
      csv = generate_mixed_csv(rows)
      File.write!(path, csv)
      csv
    end
  end

  # --- Measurement Helpers ---

  # Process heap only (what Benchee measures - misleading for sub-binaries!)
  defp measure_process_heap(fun) do
    :erlang.garbage_collect()
    {_, mem_before} = :erlang.process_info(self(), :memory)
    result = fun.()
    {_, mem_after} = :erlang.process_info(self(), :memory)
    # Keep result alive to prevent GC
    _ = result
    max(0, mem_after - mem_before)
  end

  # Total retained memory including binary references (HONEST measurement)
  defp measure_total_retained(fun) do
    :erlang.garbage_collect()

    # Get baseline
    {:memory, heap_before} = :erlang.process_info(self(), :memory)
    {:binary, bins_before} = :erlang.process_info(self(), :binary)
    bin_size_before = bins_before |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    result = fun.()

    # Force GC to clean up temporaries, but keep result
    :erlang.garbage_collect()

    {:memory, heap_after} = :erlang.process_info(self(), :memory)
    {:binary, bins_after} = :erlang.process_info(self(), :binary)
    bin_size_after = bins_after |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    # Keep result alive
    _ = result

    heap_delta = max(0, heap_after - heap_before)
    bin_delta = max(0, bin_size_after - bin_size_before)

    heap_delta + bin_delta
  end

  defp measure_reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    _ = fun.()
    {:reductions, after_reds} = Process.info(self(), :reductions)
    after_reds - before
  end

  # --- Formatting Helpers ---

  defp format_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 2)} MB"
  defp format_size(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_size(bytes), do: "#{bytes} B"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 2)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"

  defp format_time(microseconds) when microseconds >= 1_000_000 do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end
  defp format_time(microseconds) when microseconds >= 1_000 do
    "#{Float.round(microseconds / 1_000, 2)}ms"
  end
  defp format_time(microseconds), do: "#{microseconds}µs"
end

ComprehensiveBench.run()
