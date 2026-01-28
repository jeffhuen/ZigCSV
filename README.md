# ZigCSV

**Ultra-fast CSV parsing for Elixir.** A purpose-built Zig NIF with six parsing strategies, SIMD acceleration, and bounded-memory streaming. Drop-in replacement for NimbleCSV.

[![Hex.pm](https://img.shields.io/hexpm/v/zig_csv.svg)](https://hex.pm/packages/zig_csv)
[![Tests](https://img.shields.io/badge/tests-149%20passed-brightgreen.svg)]()
[![RFC 4180](https://img.shields.io/badge/RFC%204180-compliant-blue.svg)]()

## Why ZigCSV?

**The Problem**: CSV parsing in Elixir can be optimized further:

1. **Speed**: Pure Elixir parsing, while well-optimized, can't match native code with SIMD acceleration for large files.

2. **Flexibility**: NimbleCSV offers one parsing approach. Different workloads benefit from different strategies—parallel processing for huge files, streaming for unbounded data, zero-copy for maximum speed.

3. **Binary chunk streaming**: NimbleCSV's streaming requires line-delimited input. ZigCSV can process arbitrary binary chunks (useful for network streams, compressed data, etc.).

**Why Zig?** Zig offers the perfect balance for NIF development: C-level performance with modern safety features, comptime for zero-cost abstractions, and seamless C ABI compatibility. Unlike Rust NIFs that require complex bindings, Zig integrates directly with the Erlang NIF API via [Zigler](https://github.com/ityonemo/zigler).

**ZigCSV's approach**: The Zig NIF is purpose-built for BEAM integration—no wrapped libraries, no unnecessary abstractions, and resource-efficient at runtime with modular features you opt into—focusing on:

1. **Bounded memory streaming** - Process multi-GB files with ~64KB memory footprint
2. **No parent binary retention** - Data copied to BEAM terms, Zig memory freed immediately
3. **Multiple strategies** - Choose SIMD, parallel, streaming, or indexed based on your workload
4. **True zero-copy** - Sub-binary references via `enif_make_sub_binary` for maximum speed
5. **Full NimbleCSV compatibility** - Same API, drop-in replacement

## Feature Comparison

| Feature | ZigCSV | NimbleCSV |
|---------|----------|-----------|
| **Parsing strategies** | 6 (SIMD, parallel, streaming, indexed, zero_copy, basic) | 1 |
| **SIMD acceleration** | ✅ via Zig `@Vector` | ❌ |
| **Parallel parsing** | ✅ (planned) | ❌ |
| **Streaming (bounded memory)** | ✅ | ❌ (requires full file in memory) |
| **Encoding support** | ✅ UTF-8, UTF-16, Latin-1, UTF-32 | ✅ |
| **Memory model** | ✅ Choice of copy or sub-binary | Sub-binary only |
| **Stack-allocated parsing** | ✅ Zero heap allocation for parsing | Heap-based |
| **Drop-in replacement** | ✅ Same API | - |
| **RFC 4180 compliant** | ✅ 149 tests | ✅ |
| **Benchmark (4MB CSV)** | ~10ms | ~87ms |

## Purpose-Built for Elixir

ZigCSV is **custom-built from the ground up** for optimal Elixir/BEAM integration using Zig via [Zigler](https://github.com/ityonemo/zigler):

- **32-byte SIMD vectors** - Uses Zig's `@Vector(32, u8)` for AVX2/2x NEON acceleration on delimiter scanning
- **True zero-copy parsing** - `enif_make_sub_binary` creates BEAM sub-binary references without copying
- **Stack-allocated buffers** - Up to 102K rows and 1024 columns parsed without heap allocation
- **Cons-style list building** - `beam.make_list_cell` builds lists efficiently in reverse order
- **Direct term construction** - Results go straight to BEAM terms via `beam.make()`, no intermediate allocations

### Six Parsing Strategies

Choose the right tool for the job:

| Strategy | Use Case | How It Works |
|----------|----------|--------------|
| `:simd` | **Default.** Fastest for most files | SIMD-accelerated delimiter scanning via Zig `@Vector` |
| `:indexed` | Re-extracting row ranges | Two-phase index-then-extract with SIMD |
| `:zero_copy` | Maximum speed, short-lived data | Sub-binary references via `enif_make_sub_binary` |
| `:streaming` | Unbounded/huge files | Single-pass SIMD via `parse_chunk` (1.1x faster than NimbleCSV) |
| `:parallel` | Files 500MB+ with complex quoting | Multi-threaded parsing (planned) |
| `:basic` | Debugging, baselines | Simple byte-by-byte parsing |

**Memory Model Trade-offs:**

| Strategy | Memory Model | Input Binary | Best When |
|----------|--------------|--------------|-----------|
| `:simd`, `:parallel`, `:indexed`, `:basic` | Copy | Freed immediately | Default, memory-constrained |
| `:zero_copy` | Sub-binary | Kept alive | Speed-critical, short-lived results |
| `:streaming` | Copy (chunked) | Freed per chunk | Unbounded files |

```elixir
# Automatic strategy selection
CSV.parse_string(data)                           # Uses :simd (default)
CSV.parse_string(data, strategy: :zero_copy)     # Maximum speed
CSV.parse_string(huge_data, strategy: :parallel) # 500MB+ files with complex quoting
File.stream!("huge.csv") |> CSV.parse_stream()   # Bounded memory
```

## Installation

```elixir
def deps do
  [{:zig_csv, "~> 0.2.0"}]
end
```

Zig is automatically downloaded and compiled via [Zigler](https://github.com/ityonemo/zigler). No manual installation required for development.

**Note:** Unlike Rust NIFs with precompiled binaries, ZigCSV compiles on-demand. This means:
- First compile downloads Zig (~40MB, cached in `~/.cache/zig/`)
- NIF compiles in ~5 seconds
- Production deployments need Zig available at build time (not runtime)

See [docs/BUILD.md](docs/BUILD.md) for Docker, CI/CD, and deployment details.

## Quick Start

```elixir
alias ZigCSV.RFC4180, as: CSV

# Parse CSV (skips headers by default, like NimbleCSV)
CSV.parse_string("name,age\njohn,27\njane,30\n")
#=> [["john", "27"], ["jane", "30"]]

# Include headers
CSV.parse_string(csv, skip_headers: false)
#=> [["name", "age"], ["john", "27"], ["jane", "30"]]

# Stream large files with bounded memory
"huge.csv"
|> File.stream!()
|> CSV.parse_stream()
|> Stream.each(&process_row/1)
|> Stream.run()

# Dump back to CSV
CSV.dump_to_iodata([["name", "age"], ["john", "27"]])
#=> "name,age\r\njohn,27\r\n"
```

## Drop-in NimbleCSV Replacement

```elixir
# Before
alias NimbleCSV.RFC4180, as: CSV

# After
alias ZigCSV.RFC4180, as: CSV

# That's it. Same API, 3-9x faster on typical workloads.
```

All NimbleCSV functions are supported:

| Function | Description |
|----------|-------------|
| `parse_string/2` | Parse CSV string to list of rows |
| `parse_stream/2` | Lazily parse a stream (bounded memory) |
| `parse_enumerable/2` | Parse any enumerable |
| `dump_to_iodata/1` | Convert rows to iodata |
| `dump_to_stream/1` | Lazily convert rows to iodata stream |
| `to_line_stream/1` | Convert arbitrary chunks to lines |
| `options/0` | Return module configuration |

## Benchmarks

**3.5x-9x faster than NimbleCSV** on synthetic benchmarks for typical data. Up to **18x faster** on heavily quoted CSVs.

**13-28% faster than NimbleCSV** on real-world TSV files (10K+ rows). Speedup varies by data complexity—quoted fields with escapes show the largest gains.

```bash
mix run bench/csv_bench.exs
```

See [docs/BENCHMARK.md](docs/BENCHMARK.md) for detailed methodology and results.

### When to Use ZigCSV

| Scenario | Recommendation |
|----------|----------------|
| **Large files (1-500MB)** | ✅ Use `:zero_copy` or `:simd` - biggest wins |
| **Very large files (500MB+)** | ✅ Use `:parallel` with complex quoted data |
| **Huge/unbounded files** | ✅ Use `parse_stream/2` - bounded memory |
| **Memory-constrained** | ✅ Use default `:simd` - copies data, frees input |
| **Maximum speed** | ✅ Use `:zero_copy` - sub-binary refs |
| **High-throughput APIs** | ✅ Reduced scheduler load |
| **Small files (<100KB)** | Either works - NIF overhead negligible |
| **Need pure Elixir** | Use NimbleCSV |

## Custom Parsers

Define parsers with custom separators and options:

```elixir
# TSV parser
ZigCSV.define(MyApp.TSV,
  separator: "\t",
  escape: "\"",
  line_separator: "\n"
)

# Pipe-separated
ZigCSV.define(MyApp.PSV,
  separator: "|",
  escape: "\"",
  line_separator: "\n"
)

MyApp.TSV.parse_string("a\tb\tc\n1\t2\t3\n")
#=> [["1", "2", "3"]]
```

### Define Options

| Option | Description | Default |
|--------|-------------|---------|
| `:separator` | Field separator (any single byte) | `","` |
| `:escape` | Quote character | `"\""` |
| `:line_separator` | Line ending for dumps | `"\r\n"` |
| `:newlines` | Accepted line endings | `["\r\n", "\n"]` |
| `:encoding` | Character encoding (see below) | `:utf8` |
| `:trim_bom` | Remove BOM when parsing | `false` |
| `:dump_bom` | Add BOM when dumping | `false` |
| `:escape_formula` | Escape formula injection | `nil` |
| `:strategy` | Default parsing strategy | `:simd` |

### Encoding Support

ZigCSV supports character encoding conversion, matching NimbleCSV's encoding options:

```elixir
# UTF-16 Little Endian (Excel/Windows exports)
ZigCSV.define(MyApp.Spreadsheet,
  separator: "\t",
  encoding: {:utf16, :little},
  trim_bom: true,
  dump_bom: true
)

# Or use the pre-defined spreadsheet parser
alias ZigCSV.Spreadsheet
Spreadsheet.parse_string(utf16_data)
```

| Encoding | Description |
|----------|-------------|
| `:utf8` | UTF-8 (default, no conversion overhead) |
| `:latin1` | ISO-8859-1 / Latin-1 |
| `{:utf16, :little}` | UTF-16 Little Endian |
| `{:utf16, :big}` | UTF-16 Big Endian |
| `{:utf32, :little}` | UTF-32 Little Endian |
| `{:utf32, :big}` | UTF-32 Big Endian |

## RFC 4180 Compliance

ZigCSV is **fully RFC 4180 compliant** and validated against industry-standard test suites:

| Test Suite | Tests | Status |
|------------|-------|--------|
| [csv-spectrum](https://github.com/max-mapper/csv-spectrum) | 17 | ✅ All pass |
| [csv-test-data](https://github.com/sineemore/csv-test-data) | 23 | ✅ All pass |
| Edge cases (PapaParse-inspired) | 53 | ✅ All pass |
| NimbleCSV compat | 26 | ✅ All pass |
| Encoding (UTF-16, Latin-1, etc.) | 20 | ✅ All pass |
| Core functionality | 10 | ✅ All pass |
| **Total** | **149** | ✅ |

See [docs/COMPLIANCE.md](docs/COMPLIANCE.md) for full compliance details.

## How It Works

### Why Zig for NIFs?

Zig is ideal for BEAM NIF development:

1. **Direct C ABI** - No bindings layer needed; Zig calls `enif_*` functions directly
2. **Comptime** - Zero-cost abstractions via compile-time code generation
3. **SIMD built-in** - `@Vector` provides portable SIMD without platform-specific intrinsics
4. **No hidden allocations** - Full control over memory, perfect for stack-allocated parsing

ZigCSV parses directly into BEAM terms in a single pass:

1. Parse CSV → Erlang terms directly (single pass, stack-allocated)
2. Return to BEAM

### Strategy Implementations

Each strategy takes a different approach. All share direct term building, but differ in how they scan and parse:

| Strategy | Scanning | Parsing | Memory | Best For |
|----------|----------|---------|--------|----------|
| `:simd` | SIMD via `@Vector(32, u8)` | Sequential | Stack | Default, fastest for most files |
| `:indexed` | SIMD | Two-phase (index, then extract) | Stack + index | Re-extracting row ranges |
| `:zero_copy` | SIMD | Sub-binary references | Stack | Maximum speed, short-lived data |
| `:basic` | Byte-by-byte | Sequential | Stack | Debugging, correctness reference |
| `:streaming` | SIMD via `parse_chunk` | Single-pass chunks | O(chunk) | Unbounded/huge files |
| `:parallel` | SIMD | Multi-threaded | Stack | Very large files (planned) |

**Key optimizations:**
- **32-byte SIMD vectors** - `@Vector(32, u8)` processes 32 bytes per cycle (AVX2/2x NEON)
- **Stack-allocated buffers** - No heap allocation for up to 102K rows × 1024 columns
- **Cons-style list building** - `beam.make_list_cell` builds lists in O(1) per element
- **Direct term construction** - `beam.make()` creates BEAM terms without intermediate allocation

**`:zero_copy` specifics:**
- Uses `enif_make_sub_binary` for true zero-copy field extraction
- Hybrid approach: sub-binaries for clean fields, copies only when unescaping `""` → `"`
- Trade-off: keeps parent binary alive until all field references are GC'd

**`:streaming` specifics:**
- Single-pass `parse_chunk` NIF combines boundary detection and SIMD parsing
- **1.1x faster than NimbleCSV** streaming (16ms vs 18ms for 50K rows)
- Handles quote state and multi-byte encoding boundaries across chunks
- Bounded memory regardless of file size

## Architecture

ZigCSV uses inline Zig code via Zigler's `~Z` sigil for maximum performance:

```
lib/
├── zig_csv.ex          # Main module with define/2 macro
└── zig_csv/
    ├── native.ex       # Zig NIF (inline ~Z sigil)
    │   ├── SIMD utilities (simdFindAny3, simdFindByte, simdCountByte)
    │   ├── parseCSVFast - Stack-allocated SIMD parser
    │   ├── parseCSVZeroCopy - Sub-binary zero-copy parser
    │   ├── parse_chunk - Single-pass streaming (boundary + SIMD parse)
    │   └── buildIndex/createTerms - Two-phase indexed parser
    └── streaming.ex    # Streaming with single-pass NIF parsing
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed implementation notes.

## Memory Efficiency

### SmallVec-Style Parsing

ZigCSV uses a SmallVec-like pattern: stack-first with automatic heap overflow for large files.

```zig
// Stack buffers for typical CSVs (fast path)
const STACK_ROWS = 102400;
var stack_rows: [STACK_ROWS]beam.term = undefined;  // 102K rows on stack
var heap_rows: ?[]beam.term = null;                  // Spills to heap if needed

// Automatic overflow handling
if (row_count < STACK_ROWS) {
    stack_rows[row_count] = field_list;  // Fast: stack storage
} else {
    // Slow path: allocate heap, copy stack, continue
    if (heap_rows == null) heap_rows = allocator.alloc(...);
    heap_rows.?[row_count] = field_list;
}
```

This means:
- **No row limit** - handles files of any size
- **Zero heap allocation** for typical files (< 102K rows)
- **Automatic scaling** - seamlessly transitions to heap for large files
- **Cache-friendly** - sequential stack access for the common case

### Streaming for Unbounded Files

The streaming parser uses bounded memory regardless of file size:

```elixir
# Process a 10GB file with ~64KB memory
File.stream!("huge.csv", [], 65_536)
|> CSV.parse_stream()
|> Stream.each(&process/1)
|> Stream.run()
```

### Memory Tracking

For profiling Zig memory usage:

```elixir
ZigCSV.Native.reset_zig_memory_stats()
result = CSV.parse_string(large_csv)
{current, peak} = ZigCSV.Native.get_zig_memory()
IO.puts("Peak Zig memory: #{peak} bytes")
```

Note: Memory tracking stubs currently return 0. Full tracking coming in future release.

## Development

```bash
# Install dependencies
mix deps.get

# Compile (includes Zig NIF via Zigler)
mix compile

# Run tests (149 tests)
mix test

# Run benchmarks
mix run bench/csv_bench.exs

# Code quality
mix credo --strict
mix dialyzer
```

### Build Requirements

- Elixir 1.14+
- Zig 0.13+ (automatically downloaded by Zigler)
- No manual Zig installation required

## License

MIT License - see LICENSE file for details.

---

**ZigCSV** - Purpose-built Zig NIF for ultra-fast CSV parsing in Elixir.
