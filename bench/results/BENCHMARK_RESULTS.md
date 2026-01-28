# ZigCSV Benchmark Results

**Date:** January 25, 2026
**ZigCSV Version:** 0.2.0
**NimbleCSV Version:** 1.3.0

## System Information

| Property | Value |
|----------|-------|
| Elixir | 1.19.4 |
| OTP | 28 |
| OS | macOS (darwin) |
| CPU Schedulers | 10 |
| Memory Tracking | Enabled |

## Summary

ZigCSV provides significant speedups for throughput-bound workloads:

| Metric | ZigCSV (best) | NimbleCSV | Improvement |
|--------|-----------------|-----------|-------------|
| Simple CSV (333KB) | 1.39ms (zero_copy) | 4.80ms | **3.5x faster** |
| Quoted CSV (947KB) | 2.66ms (simd) | 47.65ms | **17.9x faster** |
| Mixed CSV (652KB) | 2.36ms (zero_copy) | 10.13ms | **4.3x faster** |
| Large CSV (6.8MB) | 23.85ms (zero_copy) | 219.13ms | **9.2x faster** |
| Very Large CSV (108MB) | 0.52s (zero_copy) | 4.44s | **8.6x faster** |
| BEAM Reductions | 18 (zero_copy) | 256,100 | **14,228x fewer** |

## Strategy Performance Comparison

### Simple CSV (333.6 KB, 10K rows, no quotes)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| zero_copy | 719.3 ips | 1.39ms | 3.5x faster |
| simd | 596.8 ips | 1.68ms | 2.9x faster |
| basic | 595.9 ips | 1.68ms | 2.9x faster |
| indexed | 562.4 ips | 1.78ms | 2.7x faster |
| **NimbleCSV** | 208.5 ips | 4.80ms | baseline |
| parallel | 148.6 ips | 6.73ms | 0.71x (slower) |

### Quoted CSV (946.7 KB, 10K rows, all quoted with escapes)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| simd | 375.3 ips | 2.66ms | 17.9x faster |
| zero_copy | 370.2 ips | 2.70ms | 17.6x faster |
| basic | 348.9 ips | 2.87ms | 16.6x faster |
| indexed | 325.4 ips | 3.07ms | 15.5x faster |
| parallel | 119.0 ips | 8.40ms | 5.7x faster |
| **NimbleCSV** | 21.0 ips | 47.65ms | baseline |

### Mixed/Realistic CSV (651.9 KB, 10K rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| zero_copy | 423.5 ips | 2.36ms | 4.3x faster |
| basic | 371.8 ips | 2.69ms | 3.8x faster |
| simd | 371.5 ips | 2.69ms | 3.8x faster |
| indexed | 354.0 ips | 2.83ms | 3.6x faster |
| parallel | 119.3 ips | 8.38ms | 1.2x faster |
| **NimbleCSV** | 98.8 ips | 10.13ms | baseline |

### Large CSV (6.82 MB, 100K rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| zero_copy | 41.9 ips | 23.85ms | 9.2x faster |
| basic | 35.1 ips | 28.50ms | 7.7x faster |
| simd | 34.9 ips | 28.68ms | 7.6x faster |
| indexed | 33.9 ips | 29.46ms | 7.4x faster |
| parallel | 13.5 ips | 74.28ms | 2.9x faster |
| **NimbleCSV** | 4.6 ips | 219.13ms | baseline |

### Very Large CSV (108.45 MB, 1.5M rows)

| Strategy | Throughput | Latency | vs NimbleCSV |
|----------|------------|---------|--------------|
| zero_copy | 1.93 ips | 0.52s | 8.6x faster |
| simd | 1.75 ips | 0.57s | 7.8x faster |
| parallel | 0.80 ips | 1.25s | 3.6x faster |
| **NimbleCSV** | 0.23 ips | 4.44s | baseline |

**Note:** Even at 108 MB, `:parallel` is slower than single-threaded strategies. The crossover point appears to be 500MB+ with complex quoted data.

## Memory Usage

### Important: Memory Measurement Complexity

NIF memory measurement is complex:
- **Benchee** measures process heap delta (misleading for sub-binaries)
- **Zig NIF** allocation is separate from BEAM
- **Total retained** includes both heap and binary references

### Zig NIF Memory (peak allocation during parsing)

| Strategy | Peak Allocation | Notes |
|----------|-----------------|-------|
| zero_copy | 1.67 MB | Lowest - sub-binary refs avoid copies |
| basic | 2.44 MB | Copies all field data |
| simd | 2.44 MB | Same as basic, SIMD only speeds scanning |
| parallel | 3.40 MB | Extra buffers for thread coordination |
| indexed | 3.74 MB | Index structure + field data |

### BEAM Allocation (Benchee measurement)

| Parser | Memory |
|--------|--------|
| ZigCSV (all strategies) | 1.55 KB |
| NimbleCSV | 9.41 MB |

**Key insight:** Benchee's "1.55 KB" is misleading - it measures process heap delta only. The actual parsed data exists in BEAM binaries created by the NIF.

**Bottom line:** Both parsers use memory proportional to the data. ZigCSV splits between Zig and BEAM; NimbleCSV is entirely on BEAM. Neither is dramatically more efficient.

### BEAM Reductions (scheduler work)

| Strategy | Reductions | vs NimbleCSV |
|----------|------------|--------------|
| zero_copy | 18 | 14,228x fewer |
| indexed | 18 | 14,228x fewer |
| basic | 2,800 | 91x fewer |
| simd | 3,400 | 75x fewer |
| parallel | 35,500 | 7x fewer |
| NimbleCSV | 256,100 | baseline |

**Note:** Low reductions = less scheduler overhead, but NIFs can't be preempted mid-execution.

## Streaming Comparison

**File:** 6.82 MB (100K rows)

### Fair Comparison (Both Line-Based)

| Parser | Mode | Rows | Time | Speedup |
|--------|------|------|------|---------|
| ZigCSV | line-based | 100,000 | 92.5ms | 0.96x |
| NimbleCSV | line-based | 100,000 | 88.5ms | baseline |

**Result:** NimbleCSV is slightly faster (1.04x) for line-based streaming.

### ZigCSV Unique Capability (Binary Chunks)

| Parser | Mode | Rows | Time | Correct |
|--------|------|------|------|---------|
| ZigCSV | 64KB binary chunks | 100,000 | 292.5ms | ✅ |
| NimbleCSV | 64KB binary chunks | N/A | ❌ | Requires lines |

**Key insight:** ZigCSV can process arbitrary binary chunks. NimbleCSV requires line-delimited input. This is a **capability difference**, not a speed difference.

## Correctness

- All ZigCSV strategies produce identical output ✅
- ZigCSV output matches NimbleCSV ✅

## Key Findings

1. **`:zero_copy` is fastest** for most workloads (up to 9.2x faster than NimbleCSV on 7MB file)

2. **`:simd` and `:basic` perform similarly** - SIMD acceleration has minimal impact on single-threaded parsing; field extraction dominates

3. **`:parallel` has significant overhead** - Not beneficial until 500MB+ files with complex data

4. **Memory usage is comparable** - ZigCSV allocates on Zig side, NimbleCSV on BEAM. Neither dramatically more efficient.

5. **BEAM reductions are minimal** - Up to 14,228x fewer reductions, reducing scheduler load

6. **Streaming is a capability difference** - ZigCSV handles binary chunks; speed is comparable for line-based

7. **Quoted fields show largest gains** - 17.9x faster due to efficient escape handling in Zig

## Recommendations

| Use Case | Recommended Strategy |
|----------|---------------------|
| Default | `:simd` (balanced) |
| Maximum speed | `:zero_copy` |
| Very large files (500MB+) | `:parallel` |
| Streaming/unbounded | `parse_stream/2` |
| Memory-constrained | `:simd` (copies data, frees input) |
| Debugging | `:basic` |

## Raw Output

Full benchmark output saved to: `bench/results/benchmark_output.txt`
