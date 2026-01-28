# ZigCSV Benchmarks

This document presents benchmark results comparing ZigCSV's parsing strategies against NimbleCSV.

## Test Environment

- **Elixir**: 1.19.4
- **OTP**: 28
- **Hardware**: Apple Silicon M1 Pro (10 cores)
- **ZigCSV**: 0.2.0
- **NimbleCSV**: 1.3.0
- **Test date**: January 27, 2026

## Strategies Compared

| Strategy | Description | Best For |
|----------|-------------|----------|
| `:simd` | SIMD-accelerated via Zig `@Vector(32, u8)` (default) | General use |
| `:indexed` | Two-phase index-then-extract with SIMD | Row range extraction |
| `:zero_copy` | Sub-binary references via `enif_make_sub_binary` | Maximum speed |
| `:basic` | Byte-by-byte parsing | Debugging, baseline |
| `:streaming` | Bounded-memory chunks (Elixir-based) | Unbounded files |
| `:parallel` | Multi-threaded parsing | Very large files (500MB+) |

## Throughput Benchmark Results

### Simple CSV (333 KB, 10K rows, no quotes)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| ZigCSV (simd) | 885 ips | 1.13ms | **3.79x faster** |
| ZigCSV (zero_copy) | 884 ips | 1.13ms | 3.78x faster |
| ZigCSV (parallel) | 883 ips | 1.13ms | 3.78x faster |
| ZigCSV (indexed) | 878 ips | 1.14ms | 3.76x faster |
| ZigCSV (basic) | 485 ips | 2.06ms | 2.07x faster |
| NimbleCSV | 234 ips | 4.28ms | baseline |

### Quoted CSV (947 KB, 10K rows, all fields quoted with escapes)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| ZigCSV (indexed) | 591 ips | 1.69ms | **23.71x faster** |
| ZigCSV (zero_copy) | 568 ips | 1.76ms | 22.79x faster |
| ZigCSV (simd) | 543 ips | 1.84ms | 21.78x faster |
| ZigCSV (parallel) | 542 ips | 1.84ms | 21.74x faster |
| ZigCSV (basic) | 282 ips | 3.55ms | 11.31x faster |
| NimbleCSV | 25 ips | 40.11ms | baseline |

### Mixed/Realistic CSV (652 KB, 10K rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| ZigCSV (simd) | 591 ips | 1.69ms | **5.92x faster** |
| ZigCSV (parallel) | 591 ips | 1.69ms | 5.92x faster |
| ZigCSV (zero_copy) | 589 ips | 1.70ms | 5.90x faster |
| ZigCSV (indexed) | 589 ips | 1.70ms | 5.90x faster |
| ZigCSV (basic) | 315 ips | 3.17ms | 3.15x faster |
| NimbleCSV | 100 ips | 10.00ms | baseline |

### Large CSV (6.82 MB, 100K rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| ZigCSV (zero_copy) | 58.7 ips | 17.05ms | **12.92x faster** |
| ZigCSV (parallel) | 56.4 ips | 17.75ms | 12.41x faster |
| ZigCSV (simd) | 53.8 ips | 18.58ms | 11.85x faster |
| ZigCSV (indexed) | 51.3 ips | 19.51ms | 11.29x faster |
| ZigCSV (basic) | 30.9 ips | 32.37ms | 6.80x faster |
| NimbleCSV | 4.5 ips | 220.21ms | baseline |

### Very Large CSV (108 MB, 1.5M rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| ZigCSV (zero_copy) | 3.10 ips | 322ms | **14.50x faster** |
| ZigCSV (simd) | 2.52 ips | 397ms | 11.76x faster |
| ZigCSV (parallel) | 2.32 ips | 432ms | 10.82x faster |
| NimbleCSV | 0.21 ips | 4.67s | baseline |

## Memory Comparison

### Benchee Memory Measurements (BEAM Process Heap)

| File Size | ZigCSV | NimbleCSV | Memory Reduction |
|-----------|--------|-----------|------------------|
| 333 KB (Simple) | 1.51 KB | 5,903 KB | **3,915x less** |
| 947 KB (Quoted) | 1.50 KB | 23,328 KB | **15,552x less** |
| 652 KB (Mixed) | 1.51 KB | 9,409 KB | **6,240x less** |
| 6.82 MB (Large) | 1.51 KB | 94,748 KB | **62,838x less** |
| 108 MB (Very Large) | 1.51 KB | 1,374,720 KB (1.3 GB) | **911,731x less** |

**Note:** ZigCSV shows constant ~1.5 KB BEAM heap usage because the actual parsing happens in Zig with stack allocation. The BEAM heap only holds the final result terms.

### SmallVec-Style Memory Management

ZigCSV uses fixed-size stack buffers with automatic heap overflow:

| Buffer | Size | Purpose |
|--------|------|---------|
| `stack_rows` | 800 KB | First 102,400 rows (fast path) |
| `heap_rows` | Dynamic | Overflow for large files (> 102K rows) |
| `field_buf` | 8 KB | Up to 1,024 columns per row |
| `unescape_buf` | 64 KB | Quote unescape buffer |
| **Typical** | **~900 KB** | Stack-only for most files |

**SmallVec pattern:** When a file exceeds 102K rows, ZigCSV automatically allocates heap storage, copies stack contents, and continues parsing. No row limit, no error, no configuration needed.

### Memory Tracking (Feature Flag)

ZigCSV includes compile-time memory tracking for detailed benchmarking:

```elixir
# Enable tracking: edit lib/zig_csv/native.ex line 51
# const memory_tracking_enabled = true;
# Then recompile: mix compile --force

ZigCSV.Native.reset_zig_memory_stats()
result = ZigCSV.RFC4180.parse_string(large_csv)
{current, peak} = ZigCSV.Native.get_zig_memory()
IO.puts("Peak Zig memory: #{peak} bytes")
```

When disabled (default), tracking has **zero runtime overhead** due to Zig's dead code elimination.

**Tracked Results (652 KB Mixed CSV):**

| Strategy | Zig Heap | BEAM Retained | Total |
|----------|----------|---------------|-------|
| basic | 80.1 KB | 0 B | 80.1 KB |
| simd | 0 B | 4.9 KB | 4.9 KB |
| indexed | 0 B | 4.9 KB | 4.9 KB |
| parallel | 0 B | 4.9 KB | 4.9 KB |
| zero_copy | 0 B | 4.9 KB | 4.9 KB |
| NimbleCSV | N/A | 134.0 KB | 134.0 KB |

**Key insight:** The optimized strategies (simd, indexed, parallel, zero_copy) use pure stack allocation, showing 0 B of Zig heap usage. Only `basic` uses heap allocation.

## BEAM Reductions (Scheduler Work)

| Strategy | Reductions | vs NimbleCSV |
|----------|------------|--------------|
| ZigCSV (indexed) | 20 | **12,610x fewer** |
| ZigCSV (zero_copy) | 20 | 12,610x fewer |
| ZigCSV (basic) | 2,900 | 87x fewer |
| ZigCSV (simd) | 3,200 | 79x fewer |
| ZigCSV (parallel) | 3,700 | 68x fewer |
| NimbleCSV | 252,200 | baseline |

**What this means:**
- Low reductions = less scheduler overhead
- NIFs run outside BEAM's reduction counting
- Trade-off: NIFs can't be preempted mid-execution

## Streaming Comparison

**File:** 6.82 MB (100K rows)

### Fair Comparison (Both Line-Based)

| Parser | Mode | Rows | Time | Throughput |
|--------|------|------|------|------------|
| NimbleCSV | line-based | 100,000 | 87ms | 78.3 MB/s |
| ZigCSV | line-based | 100,000 | 513ms | 13.3 MB/s |

**Result:** NimbleCSV is faster for line-based streaming due to pure Elixir implementation avoiding NIF call overhead per chunk.

### ZigCSV Unique Capability

| Parser | Mode | Rows | Time | Correct |
|--------|------|------|------|---------|
| ZigCSV | 64KB binary chunks | 100,000 | 462ms | Yes |
| NimbleCSV | 64KB binary chunks | N/A | N/A | No (requires lines) |

**Key insight:** ZigCSV can process arbitrary binary chunks (useful for network streams, compressed data, S3 range requests, etc.). NimbleCSV requires line-delimited input. This is a **capability difference**, not a speed difference.

**Binary chunk throughput:** 14.77 MB/sec

## Summary

### Speed Rankings by File Type

| File Type | Best Strategy | Speedup vs NimbleCSV |
|-----------|---------------|----------------------|
| Simple CSV | `:simd` | 3.79x |
| Quoted CSV | `:indexed` | 23.71x |
| Mixed CSV | `:simd` | 5.92x |
| Large CSV (7MB) | `:zero_copy` | 12.92x |
| Very Large CSV (108MB) | `:zero_copy` | 14.50x |

### Strategy Selection Guide

| Use Case | Recommended Strategy |
|----------|---------------------|
| Default / General use | `:simd` |
| Maximum speed | `:zero_copy` |
| Heavy quoting/escaping | `:indexed` |
| Very large files (500MB+) | `:parallel` |
| Streaming / Unbounded | `parse_stream/2` |
| Memory-constrained | `:simd` (copies data, frees input) |
| Debugging | `:basic` |

### Key Findings

1. **3.79x to 23.71x faster** than NimbleCSV across all workloads

2. **Quoted CSV sees biggest gains** - 23.71x faster due to Zig's efficient quote handling

3. **Constant ~1.5 KB BEAM memory** - Up to 911,731x less memory than NimbleCSV

4. **Stack-allocated parsing** - SmallVec pattern uses stack for typical files, auto-overflows to heap

5. **BEAM reductions minimal** - Up to 12,610x fewer reductions, reducing scheduler load

6. **Memory tracking available** - Compile-time feature flag with zero overhead when disabled

7. **Binary chunk streaming** - Unique capability for network/compressed data sources

## Running the Benchmarks

```bash
# Quick benchmark
mix run bench/csv_bench.exs

# Comprehensive benchmark (all strategies)
mix run bench/comprehensive_bench.exs

# With output capture
mix run bench/comprehensive_bench.exs 2>&1 | tee bench/results/$(date +%Y%m%d).txt
```

### Enable Memory Tracking

```elixir
# 1. Edit lib/zig_csv/native.ex line 51:
const memory_tracking_enabled = true;

# 2. Recompile
mix compile --force

# 3. Use in benchmarks
ZigCSV.Native.reset_zig_memory_stats()
result = ZigCSV.RFC4180.parse_string(csv)
{current, peak} = ZigCSV.Native.get_zig_memory()
IO.puts("Peak: #{peak} bytes")

# 4. Disable when done (restore zero overhead)
const memory_tracking_enabled = false;
mix compile --force
```
