# ZigCSV Architecture

A purpose-built Zig NIF for ultra-fast CSV parsing in Elixir. Not a wrapper around an existing library—custom-built from the ground up for optimal BEAM integration using [Zigler](https://github.com/ityonemo/zigler).

## Key Innovations

### Why Zig for NIFs?

Zig is the ideal language for BEAM NIF development:

- **Direct C ABI** - Zig calls `enif_*` functions directly, no bindings layer needed
- **Comptime** - Zero-cost abstractions via compile-time code generation
- **Built-in SIMD** - `@Vector` provides portable SIMD without platform-specific intrinsics
- **No hidden allocations** - Full control over memory, perfect for stack-allocated parsing
- **Inline in Elixir** - Zigler's `~Z` sigil embeds Zig directly in `.ex` files

### Purpose-Built, Not Wrapped

ZigCSV is **designed specifically for Elixir**:

- **Direct BEAM term construction** - `beam.make()` creates Erlang terms directly
- **True zero-copy** - `enif_make_sub_binary` creates sub-binary references
- **SmallVec-style parsing** - Stack-first with automatic heap overflow for unlimited rows
- **32-byte SIMD vectors** - `@Vector(32, u8)` for AVX2/2x NEON acceleration
- **Cons-style list building** - `beam.make_list_cell` for O(1) list construction

### Six Parsing Strategies

ZigCSV offers unmatched flexibility with six parsing strategies:

| Strategy | Innovation |
|----------|------------|
| `:simd` | Hardware-accelerated delimiter scanning via Zig `@Vector(32, u8)` |
| `:indexed` | Two-phase approach with SIMD scanning and batch term creation |
| `:zero_copy` | Sub-binary references via `enif_make_sub_binary` for maximum speed |
| `:streaming` | Elixir-based stateful parser with NIF batch processing |
| `:parallel` | Multi-threaded row parsing (planned) |
| `:basic` | Reference implementation for correctness validation |

### Memory Efficiency

- **SmallVec-style parsing** - Stack-first (102K rows) with automatic heap overflow for unlimited file sizes
- **Configurable memory model** - Choose between copying (frees input early) or sub-binaries (zero-copy)
- **Streaming bounded memory** - Process 10GB+ files with ~64KB memory footprint
- **Cache-friendly access** - Sequential stack access patterns for optimal CPU cache usage

### Validated Correctness

- **201 tests** covering RFC 4180, industry test suites, edge cases, encodings, and multi-separator/multi-byte patterns
- **Cross-strategy validation** - All strategies produce identical output
- **NimbleCSV compatibility** - Verified identical behavior for all API functions

## Quick Start

```elixir
# Use the pre-defined RFC4180 parser (like NimbleCSV.RFC4180)
alias ZigCSV.RFC4180, as: CSV

# Parse CSV (skips headers by default, like NimbleCSV)
CSV.parse_string("name,age\njohn,27\n")
#=> [["john", "27"]]

# Include headers
CSV.parse_string("name,age\njohn,27\n", skip_headers: false)
#=> [["name", "age"], ["john", "27"]]

# Choose strategy for large files
CSV.parse_string(huge_csv, strategy: :parallel)

# Use zero-copy for maximum speed (keeps parent binary alive)
CSV.parse_string(data, strategy: :zero_copy)

# Stream large files (uses bounded-memory streaming parser)
"huge.csv"
|> File.stream!()
|> CSV.parse_stream()
|> Stream.each(&process/1)
|> Stream.run()

# Dump back to CSV
CSV.dump_to_iodata([["a", "b"], ["1", "2"]])
#=> "a,b\n1,2\n"
```

## NimbleCSV API Compatibility

ZigCSV implements the complete NimbleCSV API:

| Function | Description | Status |
|----------|-------------|--------|
| `parse_string/2` | Parse CSV string to list of rows | ✅ |
| `parse_stream/2` | Lazily parse a stream | ✅ |
| `parse_enumerable/2` | Parse any enumerable | ✅ |
| `dump_to_iodata/1` | Convert rows to iodata | ✅ |
| `dump_to_stream/1` | Lazily convert rows to iodata stream | ✅ |
| `to_line_stream/1` | Convert arbitrary chunks to lines | ✅ |
| `options/0` | Return module configuration | ✅ |

### `define/2` Options

| Option | NimbleCSV | ZigCSV | Status |
|--------|-----------|----------|--------|
| `:separator` | ✅ Any | ✅ String, list of strings, multi-byte | ✅ |
| `:escape` | ✅ Any | ✅ String, multi-byte | ✅ |
| `:line_separator` | ✅ | ✅ | ✅ |
| `:newlines` | ✅ | ✅ | ✅ |
| `:trim_bom` | ✅ | ✅ | ✅ |
| `:dump_bom` | ✅ | ✅ | ✅ |
| `:reserved` | ✅ | ✅ | ✅ |
| `:escape_formula` | ✅ | ✅ | ✅ |
| `:moduledoc` | ✅ | ✅ | ✅ |
| `:encoding` | ✅ | ✅ | Full support |

### Migration from NimbleCSV

```elixir
# Before
alias NimbleCSV.RFC4180, as: CSV

# After
alias ZigCSV.RFC4180, as: CSV

# That's it! All function calls work identically.
```

### ZigCSV Extensions

ZigCSV adds options beyond NimbleCSV:

```elixir
# Choose parsing strategy (ZigCSV only)
CSV.parse_string(data, strategy: :parallel)
CSV.parse_string(data, strategy: :zero_copy)

# Multi-separator and multi-byte separator support
ZigCSV.define(MyParser,
  separator: [",", "|"],    # Split on comma OR pipe
  escape: "\""
)

ZigCSV.define(MyParser,
  separator: "||",          # Multi-byte separator
  escape: "''"              # Multi-byte escape
)
```

## Parsing Strategies

ZigCSV implements six parsing strategies, each optimized for different use cases:

| Strategy | Description | Best For |
|----------|-------------|----------|
| `:simd` | SIMD-accelerated via memchr (default) | Most files - fastest general purpose |
| `:basic` | Simple byte-by-byte parsing | Debugging, baseline comparison |
| `:indexed` | Two-phase index-then-extract | When you need to re-extract rows |
| `:parallel` | Multi-threaded via rayon | Very large files (500MB+) with complex quoting |
| `:zero_copy` | Sub-binary references | Maximum speed, controlled memory lifetime |
| `:streaming` | Stateful chunked parser | Unbounded files, bounded memory |

### Strategy Selection Guide

```
File Size        Recommended Strategy
─────────────────────────────────────────────────────────────
< 1 MB           :simd (default) or :zero_copy
1-500 MB         :simd or :zero_copy
500 MB+          :parallel (with complex quoted data) or :zero_copy
Unbounded        streaming (parse_stream)
Memory-sensitive :simd (copies data, frees input immediately)
Speed-sensitive  :zero_copy (sub-binaries, keeps input alive)
```

### Memory Model Trade-offs

| Strategy | Memory Model | Input Binary | Best When |
|----------|--------------|--------------|-----------|
| `:simd`, `:basic`, `:indexed`, `:parallel` | Copy | Freed immediately | Processing subsets, memory-constrained |
| `:zero_copy` | Sub-binary | Kept alive | Speed-critical, short-lived results |
| `:streaming` | Copy (chunked) | Freed per chunk | Unbounded files |

## Project Structure

```
lib/
├── zig_csv.ex              # Main module with define/2 macro, types, specs
└── zig_csv/
    ├── native.ex           # NIF bindings via Zigler extra_modules
    └── streaming.ex        # Elixir streaming with NIF batch parsing
        ├── stream_file/2
        ├── stream_enumerable/2
        └── parse_chunks/2

native/zig_csv/
├── main.zig                # NIF entry points, config decoding, streaming resource
├── memory.zig              # Memory tracking utilities
├── core/
│   ├── types.zig           # Config struct (multi-separator, multi-byte escape)
│   ├── scanner.zig         # SIMD scanning (simdFindAny3, findNextDelimiter, findPattern)
│   ├── field.zig           # Field unescaping with multi-byte escape support
│   ├── engine.zig          # Shared generic parse engine (ParseEngine(Emitter))
│   └── row_collector.zig   # SmallVec row storage + cons-cell list building
└── strategy/
    ├── fast.zig            # FastEmitter → SIMD parser (:simd)
    ├── basic.zig           # Delegates to fast (:basic)
    ├── zero_copy.zig       # Sub-binary references (:zero_copy)
    ├── chunk.zig           # ChunkEmitter → streaming chunk parser
    └── parallel.zig        # Multi-threaded (:parallel)
```

### Shared Parse Engine

The core `engine.zig` defines `ParseEngine(comptime Emitter: type)`, a generic parse
engine that implements the CSV parsing loop once. Each strategy provides a thin emitter
type (~30-50 lines) implementing:

  - `canAddField()` - check if field buffer has capacity
  - `onField(input, start, end, needs_unescape, config)` - emit one field
  - `onRowEnd(is_complete)` - finalize current row
  - `finish()` - build final return value

This eliminates ~240 lines of duplicated parsing logic across strategy files.

### Multi-Separator Config

The `Config` struct in `types.zig` supports:

  - Up to 8 separator patterns, each up to 16 bytes
  - Escape pattern up to 16 bytes
  - All stack-allocated (~160 bytes, no heap)
  - Runtime fast paths: `isSingleByteSep()` and `isSingleByteEsc()` branch to existing
    SIMD routines for the common single-byte case

Config is encoded for NIF transport as a length-prefixed binary:
`<<count::8, len1::8, sep1::binary-size(len1), len2::8, sep2::binary-size(len2), ...>>`

## Implementation Details

### SIMD-Accelerated Delimiter Scanning

ZigCSV uses Zig's built-in SIMD via `@Vector(32, u8)` for hardware-accelerated scanning. This processes 32 bytes per cycle on AVX2 (x86-64) or 2×16 bytes on NEON (ARM64).

```zig
const VECTOR_SIZE = 32;
const CharVector = @Vector(VECTOR_SIZE, u8);

inline fn simdFindAny3(haystack: []const u8, a: u8, b: u8, c: u8) ?usize {
    var i: usize = 0;

    // Process 32 bytes at a time
    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: CharVector = haystack[i..][0..VECTOR_SIZE].*;

        // Parallel comparison - all 32 bytes checked simultaneously
        const matches = (chunk == @as(CharVector, @splat(a))) |
                        (chunk == @as(CharVector, @splat(b))) |
                        (chunk == @as(CharVector, @splat(c)));

        if (@reduce(.Or, matches)) {
            // Found a match - get position via count trailing zeros
            const mask: u32 = @bitCast(matches);
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    // Scalar fallback for remainder (< 32 bytes)
    while (i < haystack.len) {
        const c_byte = haystack[i];
        if (c_byte == a or c_byte == b or c_byte == c) return i;
        i += 1;
    }
    return null;
}
```

This approach:
- Loads 32 bytes into a SIMD register
- Compares all 32 bytes against 3 targets in parallel
- Uses `@reduce(.Or, ...)` to check if any match exists
- Uses `@ctz` (count trailing zeros) to find the first match position

### Quote Handling with Unescaping

All strategies properly handle CSV quote escaping (doubled quotes `""` → `"`).
The `unescapeField` function in `field.zig` supports both single-byte and
multi-byte escape patterns:

```zig
// Multi-byte escape support: e.g., escape="''" means ''''→''
pub fn unescapeField(input: []const u8, config: *const Config, output: []u8) usize {
    if (config.isSingleByteEsc()) {
        return unescapeSingleByte(input, config.escByte(), output);
    }
    // General multi-byte path: scan for doubled escape patterns
    const esc = config.getEscape();
    const esc_len = config.esc_len;
    // ... scan and copy, skipping one copy of each doubled escape
}
```

For single-byte escapes, the fast path compiles to the same code as the
original implementation with no overhead.

### SmallVec-Style Memory Management

ZigCSV uses a SmallVec-like pattern for row storage: fast stack allocation for typical files with automatic heap overflow for large files.

```zig
// SmallVec-like storage: stack first, spill to heap for large files
const STACK_ROWS = 102400;
var stack_rows: [STACK_ROWS]beam.term = undefined;  // Fast path
var heap_rows: ?[]beam.term = null;                  // Overflow storage
var heap_capacity: usize = 0;
defer if (heap_rows) |h| allocator.free(h);

// During parsing: store each row
if (row_count < STACK_ROWS) {
    // Fast path: stack storage (no allocation)
    stack_rows[row_count] = field_list;
} else {
    // Slow path: spill to heap
    if (heap_rows == null) {
        // First overflow: allocate and copy stack contents
        heap_capacity = STACK_ROWS * 2;
        heap_rows = allocator.alloc(beam.term, heap_capacity) catch break;
        @memcpy(heap_rows.?[0..STACK_ROWS], &stack_rows);
    } else if (row_count >= heap_capacity) {
        // Grow heap buffer when needed
        heap_rows = allocator.realloc(heap_rows.?, heap_capacity * 2) catch break;
        heap_capacity *= 2;
    }
    heap_rows.?[row_count] = field_list;
}
```

This approach:
- Uses ~800KB stack for the first 102K rows (zero allocation overhead)
- Automatically transitions to heap when overflow occurs
- Doubles heap capacity on each growth (amortized O(1) inserts)
- Handles unlimited file sizes with no configuration

### Strategy A: Basic Parser (`:basic`)

Delegates to the fast parser. The scanner module includes a scalar fallback path
that activates for the final < 32 bytes, so basic and SIMD produce identical results.
Kept as a separate API entry point for backward compatibility.

### Strategy B: SIMD Parser (`:simd`) - Default

The fastest general-purpose strategy using SIMD-accelerated delimiter scanning.
Implemented as a thin `FastEmitter` plugged into the shared `ParseEngine`:

```zig
// FastEmitter — the complete strategy implementation (~50 lines)
const FastEmitter = struct {
    collector: RowCollector = .{},
    field_buf: [MAX_FIELDS]beam.term = undefined,
    unescape_buf: [65536]u8 = undefined,
    field_count: usize = 0,

    pub fn onField(self: *FastEmitter, input: []const u8,
                   start: usize, end: usize, needs_unescape: bool,
                   config: *const Config) void {
        if (needs_unescape) {
            const len = field_mod.unescapeField(input[start..end], config, &self.unescape_buf);
            self.field_buf[self.field_count] = beam.make(self.unescape_buf[0..len], .{});
        } else {
            self.field_buf[self.field_count] = beam.make(input[start..end], .{});
        }
        self.field_count += 1;
    }

    pub fn onRowEnd(self: *FastEmitter, _: bool) void {
        const field_list = row_collector.buildFieldList(&self.field_buf, self.field_count);
        self.collector.addRow(field_list);
        self.field_count = 0;
    }

    pub fn finish(self: *FastEmitter) beam.term {
        return self.collector.buildList();
    }
};

// Single public function — all parsing logic lives in the shared engine
pub fn parseCSVFast(input: []const u8, config: Config) beam.term {
    var emitter = FastEmitter{};
    defer emitter.collector.deinit();
    return engine.ParseEngine(FastEmitter).parse(input, config, &emitter);
}
```

The shared engine handles quoted/unquoted field detection, separator matching
(including multi-separator and multi-byte patterns), and newline handling.
For single-byte separators, the engine's fast path uses `simdFindAny3` for
maximum throughput.

### Strategy C: Indexed Parser (`:indexed`)

Currently delegates to the SIMD fast parser. The scanner module provides
scalar fallback automatically, so no separate implementation is needed.

### Strategy D: Streaming Parser (`:streaming`)

Implemented in pure Elixir for state management, with NIF batch parsing:

```elixir
# State: {buffer, parsed_rows, encoded_seps, escape}
# Each chunk: append to buffer, find complete rows via NIF, parse with NIF
{parsed, consumed} = ZigCSV.Native.parse_chunk_encoded(data, encoded_seps, escape)
remaining = binary_part(data, consumed, byte_size(data) - consumed)
```

Key features:
- Quote-aware chunk splitting via `findLastCompleteRow` in the Zig engine
- NIF batch parsing via `parse_chunk_encoded` (boundary detection + parsing in one call)
- Handles multi-byte encoding boundaries across chunks
- Supports multi-separator and multi-byte separator/escape patterns

### Strategy E: Parallel Parser (`:parallel`)

Planned for future implementation using `std.Thread` for multi-threaded row parsing.

### Strategy F: Zero-Copy Parser (`:zero_copy`)

Returns BEAM sub-binary references instead of copying data:

```zig
fn parseCSVZeroCopy(input_term: beam.term, config: Config) beam.term {
    const env = beam.context.env;
    var bin: e.ErlNifBinary = undefined;
    _ = e.enif_inspect_binary(env, input_term.v, &bin);

    // For each field...
    if (needs_unescape) {
        // Must copy and unescape: "val""ue" -> val"ue
        field_buf[field_count] = beam.make(unescape_buf[0..len], .{});
    } else {
        // Zero-copy: create sub-binary reference
        field_buf[field_count] = .{
            .v = e.enif_make_sub_binary(env, input_term.v, start, len)
        };
    }
}
```

**Hybrid approach**:
- Unquoted fields → sub-binary (zero-copy)
- Quoted without escapes → sub-binary of inner content (zero-copy)
- Quoted with escapes → copy and unescape (must allocate)

**Trade-off**: Sub-binaries keep the parent binary alive until all field references are garbage collected.

---

## Performance Optimizations

### Stack-Allocated Buffers

ZigCSV avoids heap allocation by using stack-allocated buffers:

```zig
// Stack buffers - no heap allocation for typical CSVs
var row_terms: [102400]beam.term = undefined;  // 102K rows max
var field_buf: [1024]beam.term = undefined;    // 1024 columns max
var unescape_buf: [65536]u8 = undefined;       // 64KB unescape buffer
```

Benefits:
- **Zero heap allocation** for files up to 102K rows × 1024 columns
- **Predictable memory** - stack size is fixed regardless of input
- **Cache-friendly** - sequential stack access patterns
- **No allocator overhead** - no malloc/free calls during parsing

### 32-Byte SIMD Vectors

Using 32-byte vectors maximizes throughput on modern CPUs:

```zig
const VECTOR_SIZE = 32;  // AVX2 register size / 2× NEON
const CharVector = @Vector(VECTOR_SIZE, u8);
```

This processes:
- **32 bytes per cycle** on x86-64 with AVX2
- **2×16 bytes per cycle** on ARM64 with NEON
- Automatic fallback to scalar for the final < 32 bytes

### Cons-Style List Building

Lists are built in reverse order using cons cells for O(1) per element:

```zig
// Build field list using cons cells (O(1) per element)
var field_list = beam.make_empty_list(.{});
var i: usize = field_count;
while (i > 0) {
    i -= 1;
    field_list = beam.make_list_cell(field_buf[i], field_list, .{});
}
```

This avoids the O(n) cost of appending to lists.

### Direct BEAM Term Construction

Terms are created directly without intermediate allocations:

```zig
// Direct binary term creation
field_buf[field_count] = beam.make(input[start..pos], .{});

// Or zero-copy sub-binary reference
field_buf[field_count] = .{
    .v = e.enif_make_sub_binary(env, input_term.v, start, len)
};
```

### Release Mode Optimization

ZigCSV uses Zigler's `optimize: :fast` for release builds:

```elixir
use Zig, otp_app: :zig_csv, optimize: :fast
```

This enables:
- Full LLVM optimizations
- Function inlining
- Loop unrolling
- Dead code elimination

---

## Background: Why a Zig NIF?

### NimbleCSV Strengths

NimbleCSV is remarkably fast for pure Elixir:
- Binary pattern matching is highly optimized
- Sub-binary references provide zero-copy field extraction
- Match context optimization for continuous parsing

### Why Zig Over Rust for NIFs?

1. **Simpler FFI** - Zig has direct C ABI, no bindings layer needed
2. **Built-in SIMD** - `@Vector` is portable without platform-specific intrinsics
3. **Comptime** - Zero-cost abstractions via compile-time evaluation
4. **Inline in Elixir** - Zigler's `~Z` sigil embeds Zig in `.ex` files
5. **Faster compilation** - Zig compiles significantly faster than Rust

### ZigCSV Advantages

1. **Multiple strategies** - Choose the right tool for each workload
2. **Streaming support** - Process arbitrarily large files with bounded memory
3. **SIMD acceleration** - 32-byte vector processing via `@Vector`
4. **Competitive speed** - 2.5-4x faster than NimbleCSV on typical workloads
5. **Flexible memory model** - Copy or sub-binary, your choice
6. **Stack-allocated** - No heap allocation for typical files

## NIF Safety

### The 1ms Rule

NIFs should complete in under 1ms to avoid blocking schedulers.

| Approach | Used By | Description |
|----------|---------|-------------|
| Fast SIMD | `:simd`, `:indexed`, `:zero_copy` | Complete quickly via hardware acceleration |
| Chunked Processing | `:streaming` | Return control between chunks (Elixir-based) |
| Dirty Schedulers | `:parallel` (planned) | Separate from normal schedulers |

### Memory Safety

- Stack-allocated buffers have fixed maximum sizes (102K rows, 1024 columns)
- Copy-based strategies copy data to BEAM terms, Zig stack freed on return
- Zero-copy strategy creates sub-binary references (no Zig allocation)
- Streaming uses Elixir state management, NIF calls are stateless

## Benchmark Results

- **100K rows (4MB)**: 2.5-4x faster than NimbleCSV
- **Peak throughput**: ~377 MB/s with `:zero_copy` strategy
- **Streaming**: Bounded memory for arbitrary file sizes

The speedup varies by data complexity—quoted fields with escapes show the largest gains.

See [BENCHMARK.md](BENCHMARK.md) for detailed methodology, real-world results, and raw data.

## Documentation

ZigCSV includes comprehensive documentation for hexdocs:

- **Module docs**: Detailed guides with examples
- **Type specs**: `@type`, `@typedoc` for all public types
- **Function specs**: `@spec` for all public functions
- **Examples**: Runnable examples in docstrings
- **Callbacks**: Full behaviour definition for generated modules

## Compliance & Validation

ZigCSV is validated against industry-standard CSV test suites to ensure correctness:

- **RFC 4180 Compliance** - Full compliance with the CSV specification
- **csv-spectrum** - Industry "acid test" for CSV parsers (12 test cases)
- **csv-test-data** - Comprehensive RFC 4180 test suite (17+ test cases)
- **Cross-strategy validation** - All strategies produce identical output

See [COMPLIANCE.md](COMPLIANCE.md) for full details on test suites and validation methodology.

## Future Work

- **True parallel parsing** - Multi-threaded via `std.Thread`
- **Memory tracking** - Instrument Zig allocations for profiling
- **Error positions** - Line/column numbers in ParseError
- **Streaming with multi-byte separators** - Full multi-byte boundary detection across chunks

## References

- [RFC 4180](https://tools.ietf.org/html/rfc4180) - CSV specification
- [csv-spectrum](https://github.com/max-mapper/csv-spectrum) - CSV acid test suite
- [csv-test-data](https://github.com/sineemore/csv-test-data) - RFC 4180 test data
- [NimbleCSV Source](https://github.com/dashbitco/nimble_csv)
- [BEAM Binary Handling](https://www.erlang.org/doc/efficiency_guide/binaryhandling.html)
- [Zigler](https://github.com/ityonemo/zigler) - Zig NIFs for Elixir
- [Zig Language Reference](https://ziglang.org/documentation/master/) - Zig documentation
- [Zig SIMD](https://ziglang.org/documentation/master/#Vectors) - Zig vector types
