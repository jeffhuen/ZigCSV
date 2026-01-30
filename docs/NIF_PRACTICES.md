# Elixir NIF Best Practices with Zigler

A comprehensive checklist for building NIFs that preserve BEAM fault tolerance while leveraging Zig performance. Targets Zigler 0.15.2, Zig 0.15.x, Elixir 1.20, OTP 26-28.

---

## The Fundamental Contract

```
Elixir side:                         Zig side:
─────────────                        ────────
Fault tolerance (supervisors)   ←→   No panics / undefined behavior
GC manages memory               ←→   beam.Resource + deinit cleanup
Preemptive scheduling            ←→   Dirty/threaded for heavy work
Message passing concurrency      ←→   Mutex or atomic for shared state
{:ok, _} / {:error, _} tuples  ←→   beam.make(.{.ok, val}, .{})
Pattern matching on atoms        ←→   Zig enums marshal as atoms
Process isolation                ←→   No global mutable state
```

Zig handles the hot path. BEAM handles the lifecycle. Zig never decides when to create, destroy, or schedule — it only does compute when the BEAM asks, and returns control as fast as possible.

---

## 1. Scheduler Discipline — Never Block the BEAM

Per Erlang docs, any NIF that cannot finish in ~1ms should run on dirty schedulers or a dedicated thread. Zigler provides concurrency modes via `use Zig` options.

- [ ] Use `:dirty_cpu` for any CPU-bound work (parsing, hashing, compression, encryption, image processing)
- [ ] Use `:dirty_io` for I/O-bound work (file reads, network calls, database queries)
- [ ] Leave fast O(1) lookups and trivial accessors on the normal scheduler — dirty scheduler context-switch overhead would dominate
- [ ] For long-running work that sends messages back, use `:threaded` mode with `beam.yield()` checkpoints
- [ ] If a NIF conditionally does heavy or light work, default to dirty scheduling — the cost of an unnecessary dirty switch is far less than blocking a normal scheduler
- [ ] Use `beam.yield()` in dirty/threaded NIFs to cooperate with process termination

```elixir
# Configure concurrency per-function in use Zig
use Zig,
  otp_app: :my_app,
  nifs: [
    parse_document: [:dirty_cpu],   # CPU-heavy: always dirty
    read_file: [:dirty_io],         # I/O-bound: dirty IO
    get_count: [],                  # Fast accessor: normal scheduler
    background_scan: [:threaded],   # Long-running with message passing
  ]
```

```zig
// CPU-heavy work — configured as :dirty_cpu in Elixir
pub fn parse_document(input: []const u8) beam.term {
    // ... heavy parsing logic ...
}

// Fast accessor — runs on normal scheduler
pub fn get_count(resource: MyResource) usize {
    return resource.count;
}

// Long-running threaded NIF — must yield cooperatively
pub fn background_scan(pid: beam.pid, input: []const u8) !void {
    defer { beam.send(pid, .done, .{}) catch {}; }
    var offset: usize = 0;
    while (offset < input.len) {
        // Process a chunk
        offset += process_chunk(input[offset..]);
        try beam.yield(); // cooperative checkpoint — returns error if process killed
    }
}
```

---

## 2. Resource Lifecycle — Let BEAM GC Own Zig Memory

`beam.Resource` is the bridge between BEAM garbage collection and Zig ownership. When the Elixir term holding the reference is collected, Zig's cleanup function runs automatically.

- [ ] Wrap all long-lived Zig state in `beam.Resource(T, ...)`
- [ ] Declare resources in `use Zig` with `resources: [:MyResource]`
- [ ] Provide a `deinit` method or a cleanup function for resource deallocation
- [ ] Never manually free resources from Elixir — trust BEAM GC + Zig cleanup
- [ ] Keep cleanup implementations fast and non-blocking — resource cleanup happens at GC time
- [ ] If cleanup requires heavy work, defer it (e.g., signal a background worker) rather than doing it inline
- [ ] In threaded NIFs, use `__resource__.keep/release` to prevent use-after-free

```zig
pub const ParserState = struct {
    buffer: std.ArrayListUnmanaged(u8),
    config: Config,

    pub fn init(config: Config) ParserState {
        return .{
            .buffer = .{},
            .config = config,
        };
    }

    pub fn deinit(self: *ParserState) void {
        self.buffer.deinit(beam.allocator);
    }
};

// Declared in use Zig: resources: [:ParserResource]
pub const ParserResource = beam.Resource(ParserState, @import("root"), .{});
```

```elixir
use Zig,
  otp_app: :my_app,
  resources: [:ParserResource],
  zig_code_path: "./native/main.zig"
```

---

## 3. Safety — NIFs Must Not Crash the VM

Unlike Rustler, Zigler does **not** automatically catch panics. Zig's safety checks (bounds, overflow, null dereference) in debug/safe modes produce traps that will crash the entire BEAM VM. In release modes (`:fast`, `:small`), these checks are removed entirely — undefined behavior can corrupt memory silently.

The rule: **undefined behavior in a NIF crashes the entire VM. No supervisor can recover.**

- [ ] **Never index arrays without bounds checking in NIF code** — use `if (i < slice.len)` guards or return error unions
- [ ] **Use error unions (`!T`) for all fallible operations** — Zigler translates error returns to Elixir exceptions
- [ ] **Validate all inputs at the NIF boundary** — treat the NIF as a system boundary, like an API endpoint
- [ ] **Never use `@panic` for error handling** — panics in NIFs crash the VM
- [ ] **Avoid `unreachable` except where truly unreachable** — if hit, it crashes the VM in debug mode and is UB in release
- [ ] **Use `beam.make` error tuples for recoverable errors** — return `{:error, reason}` instead of crashing
- [ ] **Test edge cases**: empty input, malformed input, extremely large input, concurrent access
- [ ] **Build in `:safe` mode during development** — catches more UB than `:fast` but still crashes on traps
- [ ] **Use `beam.allocator` and handle allocation failure** — `catch` OOM rather than letting it trap

```zig
// Return error tuples for recoverable failures
pub fn safe_parse(input: []const u8) beam.term {
    var emitter = Emitter{};
    defer emitter.deinit();

    engine.parse(input, config, &emitter);

    if (emitter.has_error) {
        return beam.make(.{ .error, emitter.error_reason() }, .{});
    }
    return beam.make(.{ .ok, emitter.finish() }, .{});
}

// Use error unions for operations that can fail
pub fn validated_parse(input: []const u8) !beam.term {
    if (input.len == 0) {
        return beam.make(.{ .error, .empty_input }, .{});
    }
    if (input.len > MAX_INPUT_SIZE) {
        return beam.make(.{ .error, .input_too_large }, .{});
    }
    // ... parse ...
}
```

---

## 4. Mutex Strategy — Shared Mutable State

Zig's `std.Thread.Mutex` protects mutable state in resources accessed from multiple BEAM processes. Unlike Rust's `Mutex`, Zig mutexes don't have a poison concept — but you still need to handle contention correctly.

- [ ] Use `std.Thread.Mutex` for mutable state inside resources — any BEAM process can call a NIF on the same resource concurrently
- [ ] Hold locks for the minimum possible duration — acquire, do work, release
- [ ] Never hold locks while building large BEAM term trees or calling `beam.make` for complex structures
- [ ] Consider lock-free atomic operations (`std.atomic`) for simple counters and flags
- [ ] If you need read-write semantics, use `std.Thread.RwLock` — but only if profiling proves read contention is a bottleneck

```zig
pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    data: ?ParsedDocument = null,

    pub fn withData(self: *SharedState, comptime f: fn (*ParsedDocument) beam.term) beam.term {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data) |*doc| {
            return f(doc);
        }
        return beam.make(.{ .error, .no_document }, .{});
    }
};
```

---

## 5. Memory Boundaries — Respect BEAM Heap Ownership

The BEAM and Zig have separate memory spaces. Data crosses the boundary through Zigler's marshalling.

- [ ] `[]const u8` input is marshalled from BEAM — Zigler handles the conversion, but the data is valid only for the NIF call duration
- [ ] If data must outlive the NIF call, copy it into Zig-owned memory using `beam.allocator`
- [ ] Use `beam.make(value, .{})` to construct BEAM terms — this copies data into BEAM-managed memory
- [ ] Cap all pre-allocation sizes based on validated input, not raw user-provided lengths — prevents OOM
- [ ] Never store `beam.term` values in resources expecting them to survive across NIF calls — terms are bound to the NIF's environment
- [ ] Use `beam.allocator` (backed by BEAM's NIF allocator) for Zig-side allocations — it provides better cache locality and VM memory accounting

```zig
// WRONG: storing a beam.term in a resource
const Bad = struct { cached_term: beam.term };  // term dies after NIF returns

// RIGHT: own the data in Zig
const Good = struct { data: []u8 };  // allocated with beam.allocator

// Stack-first pattern for performance
const Collector = struct {
    stack_buf: [4096]beam.term = undefined,  // stack storage for common case
    heap_buf: ?[]beam.term = null,           // heap fallback for large inputs
    count: usize = 0,

    pub fn deinit(self: *Collector) void {
        if (self.heap_buf) |buf| beam.allocator.free(buf);
    }
};
```

---

## 6. Term Construction — Minimize Boundary Crossings

Each NIF call has non-trivial overhead. Term construction with `beam.make` is where most NIF time is spent.

- [ ] Provide batch accessor NIFs that return multiple values in a single call
- [ ] Build Erlang lists in reverse with `beam.make_list_cell` — prepending is O(1), appending is O(n)
- [ ] Return `beam.Resource` for intermediate results instead of full term trees — keep data in Zig, access incrementally from Elixir
- [ ] Use `beam.make` to build tuples, maps, and lists in Zig
- [ ] Pre-define atoms as Zig enum values — Zigler marshals enums as atoms automatically
- [ ] For large result sets, consider serializing to a binary format and deserializing on the Elixir side

```zig
const beam = @import("beam");

// Zig enums become atoms automatically — no manual atom table needed
const Status = enum { ok, error, partial, unterminated_escape, oom };

// Build result lists in reverse for O(1) prepend
fn buildList(items: []const beam.term) beam.term {
    var list = beam.make_empty_list(.{});
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        list = beam.make_list_cell(items[i], list, .{});
    }
    return list;
}

// Batch accessor — one NIF call instead of N
pub fn get_texts(resource: MyResource, start: usize, count: usize) beam.term {
    const end = @min(start + count, resource.total_count);
    var list = beam.make_empty_list(.{});
    var i: usize = end;
    while (i > start) {
        i -= 1;
        list = beam.make_list_cell(beam.make(resource.text_at(i), .{}), list, .{});
    }
    return list;
}
```

---

## 7. Error Propagation — Elixir-Idiomatic Returns

- [ ] Return `{:ok, result}` / `{:error, reason}` tuples using `beam.make(.{.ok, val}, .{})`
- [ ] Use atoms (Zig enums) for known error categories
- [ ] Use strings for dynamic error messages (parse errors with positions, validation details)
- [ ] Use `beam.make_error_pair(reason, .{})` as a shorthand for `{:error, reason}`
- [ ] Error unions (`!T`) raise `ErlangError` on the Elixir side — use for truly exceptional cases
- [ ] Document every possible error return in the Elixir wrapper module's `@doc` and `@spec`
- [ ] On the Elixir side, provide both `fun/n` (returns tuple) and `fun!/n` (raises on error) variants

```zig
// Error tuples for expected failures
pub fn parse(input: []const u8) beam.term {
    if (input.len == 0) {
        return beam.make(.{ .error, .empty_input }, .{});
    }
    // ... parsing logic ...
    if (emitter.unterminated_quote) {
        return beam.make(.{ .partial, .unterminated_escape, rows }, .{});
    }
    return rows;
}
```

```elixir
@spec parse(binary()) :: {:ok, [[binary()]]} | {:error, atom()}
def parse(csv), do: Native.parse(csv)

@spec parse!(binary()) :: [[binary()]]
def parse!(csv) do
  case Native.parse(csv) do
    {:ok, rows} -> rows
    {:error, reason} -> raise "CSV parse error: #{reason}"
    {:partial, error, _rows} -> raise "CSV parse error: #{error}"
  end
end
```

---

## 8. Concurrency Model — Align with OTP

- [ ] Resources can be shared across processes — any Elixir process can hold and use a resource reference
- [ ] Never assume single-threaded access — multiple Elixir processes may call NIFs on the same resource concurrently
- [ ] Use `std.Thread.Mutex` for shared mutable state (see Section 4)
- [ ] For threaded NIFs, use `beam.send(pid, msg, .{})` to communicate back to BEAM
- [ ] Always pair `__resource__.keep`/`__resource__.release` in threaded NIFs to prevent use-after-free
- [ ] Use `beam.yield()` in threaded NIFs — must return within 750μs of a yield call
- [ ] Avoid global mutable state — it breaks process isolation
- [ ] If you need cross-NIF state, use a resource passed through Elixir, not Zig globals

---

## 9. Streaming / Chunked Processing

For workloads too large to process in a single NIF call, use the feed-drain streaming pattern.

- [ ] Create a stateful resource (parser, accumulator, etc.) as a `beam.Resource`
- [ ] Provide `feed(resource, chunk)` NIFs that accept incremental input
- [ ] Provide `take(resource, max)` NIFs that drain processed results
- [ ] Provide a `finalize(resource)` NIF for end-of-stream handling
- [ ] Keep chunk sizes reasonable — the Elixir side controls backpressure
- [ ] Status NIFs (`available_count`, `buffer_size`) let Elixir make informed scheduling decisions

```zig
pub const StreamState = struct {
    buffer: std.ArrayListUnmanaged(u8),
    config: Config,

    pub fn init(config: Config) StreamState {
        return .{ .buffer = .{}, .config = config };
    }

    pub fn deinit(self: *StreamState) void {
        self.buffer.deinit(beam.allocator);
    }
};

pub const StreamResource = beam.Resource(StreamState, @import("root"), .{});

pub fn streaming_new() StreamResource {
    return StreamResource.create(.init(.default()), .{}) catch
        return beam.raise_exception(.resource_alloc_failed, .{});
}

// Returns {rows, buffer_size}
pub fn streaming_feed(resource: StreamResource, chunk: []const u8) beam.term {
    var state = resource.unpack();
    state.buffer.appendSlice(beam.allocator, chunk) catch {
        return beam.make(.{ .error, .oom }, .{});
    };
    const rows = process_complete_rows(state);
    return beam.make(.{ rows, state.buffer.items.len }, .{});
}

pub fn streaming_finalize(resource: StreamResource) beam.term {
    var state = resource.unpack();
    defer state.buffer.clearRetainingCapacity();
    return process_remaining(state);
}

pub fn streaming_status(resource: StreamResource) beam.term {
    const state = resource.unpack();
    return beam.make(.{ state.buffer.items.len }, .{});
}
```

---

## 10. Input Validation

- [ ] Validate all inputs at the NIF boundary before passing to Zig internals — the NIF is a system boundary
- [ ] Check for integer overflow on sizes: use `std.math.add` or `@addWithOverflow`
- [ ] Cap allocation sizes: `@min(count, known_upper_bound)` prevents OOM from malformed input
- [ ] Reject obviously invalid input early — don't waste dirty scheduler time on garbage
- [ ] For binary input, consider a quick validation pass before full parsing
- [ ] Return descriptive error tuples, not silent failures

```zig
// Prevent overflow and OOM
pub fn get_range(resource: MyResource, start: usize, count: usize) beam.term {
    const total = resource.total_count;
    const end_result = @addWithOverflow(start, count);
    if (end_result[1] != 0) {  // overflow occurred
        return beam.make(.{ .error, .overflow }, .{});
    }
    const end = @min(end_result[0], total);
    const actual_start = @min(start, total);
    // ... safe to proceed ...
}
```

---

## 11. Performance Tuning

- [ ] Use `beam.allocator` for BEAM-visible memory accounting — it wraps the NIF allocator with better cache locality
- [ ] Use `beam.debug_allocator` during development to catch leaks; ship with `beam.allocator`
- [ ] Enable `leak_check: true` per-function during development
- [ ] Leverage Zig's `@Vector` SIMD intrinsics for hot loops (delimiter scanning, byte search)
- [ ] Use `@prefetch` for predictable memory access patterns
- [ ] Prefer stack allocation with heap fallback for common-case-small, worst-case-large data
- [ ] Benchmark NIF overhead separately from Zig computation — term construction cost often dominates
- [ ] Use `:fast` optimization for production, `:safe` for development

```zig
// SIMD delimiter scanning example
const VECTOR_SIZE = 32;
const Vec = @Vector(VECTOR_SIZE, u8);

fn scanForDelimiter(input: []const u8, delimiter: u8) ?usize {
    const splat: Vec = @splat(delimiter);
    var offset: usize = 0;
    while (offset + VECTOR_SIZE <= input.len) : (offset += VECTOR_SIZE) {
        const chunk: Vec = input[offset..][0..VECTOR_SIZE].*;
        const matches = chunk == splat;
        const mask = @as(u32, @bitCast(matches));
        if (mask != 0) {
            return offset + @ctz(mask);
        }
    }
    // scalar fallback for remainder
    while (offset < input.len) : (offset += 1) {
        if (input[offset] == delimiter) return offset;
    }
    return null;
}
```

---

## 12. Dependency Discipline — Zig's stdlib First

Zig has no package manager ecosystem comparable to crates.io. Dependencies are managed through `build.zig.zon` or vendored source. This naturally encourages minimal dependencies — but the principle still applies.

### Default to the Standard Library and Handrolling

- [ ] **Zig's `std` is comprehensive** — `std.mem`, `std.hash_map`, `std.ArrayList`, `std.sort`, `std.fmt`, `std.math`, `std.Thread`, `std.atomic` cover most needs
- [ ] **If you can write it in under ~100 lines of clear, correct Zig, write it yourself** — a custom hash, a small LRU, a bitmask set
- [ ] **Zig's comptime enables zero-cost abstractions** — generic data structures, compile-time string processing, type-safe builders without runtime overhead
- [ ] **`@Vector` SIMD is built into the language** — no external crate needed for vectorized operations
- [ ] **Copy a function, not a dependency** — if you need one utility from a library, extract it

### When a Dependency Is Justified

- [ ] **C libraries via Zig's C interop** — `@cImport` makes wrapping C trivial. Use battle-tested C libraries for complex formats, crypto, compression
- [ ] **Zigler's C integration** — use `c:` options in `use Zig` to link system libraries or compile C sources
- [ ] **Cryptography** — never handroll crypto
- [ ] **Complex format parsers** — full XML/JSON/protobuf spec compliance is a project in itself

### Evaluating a Dependency

- [ ] **Check transitive dependencies** — Zig's explicit dependency model helps here
- [ ] **Check binary size impact** — Zig produces lean binaries but C dependencies can bloat
- [ ] **Check `@cImport` safety** — C code in a NIF can crash the VM just like unsafe Zig
- [ ] **Prefer Zig-native over C wrappers** — better error handling, comptime optimization, no FFI overhead

---

## 13. Build & Distribution

- [ ] Set `runtime: false` in the Zigler dependency — it's a compile-time tool only
- [ ] Pin Zigler version explicitly (`{:zigler, "~> 0.15"}`)
- [ ] Choose optimization mode: `:fast` for production, `:safe` or `:debug` for development
- [ ] Use `zig_code_path` for external Zig files rather than inline `~Z` sigils for non-trivial code
- [ ] Use `extra_modules` to declare multi-file Zig projects with dependency graphs
- [ ] Run `mix format` with Zig formatting configured for `.zig` files
- [ ] Test on all target OTP versions — NIF ABI compatibility matters
- [ ] Set `ZIGLER_STAGING_ROOT` in CI for reproducible builds

```elixir
# mix.exs
use Zig,
  otp_app: :my_app,
  optimize: :fast,
  resources: [:MyResource],
  zig_code_path: "./native/main.zig",
  extra_modules: [
    types: {"./native/core/types.zig", []},
    scanner: {"./native/core/scanner.zig", [:types]},
    engine: {"./native/core/engine.zig", [:types, :scanner]},
  ]
```

---

## 14. Elixir-Side Wrapper Patterns

- [ ] Wrap every NIF in an Elixir function with `@doc`, `@spec`, and a descriptive name
- [ ] Provide `fun/n` (returns `{:ok, _} | {:error, _}`) and `fun!/n` (raises) variants
- [ ] Zigler auto-generates `@spec` from Zig type signatures — verify they match your intent
- [ ] Provide Elixir fallback function bodies — they execute if the NIF fails to load
- [ ] Document which functions run on dirty schedulers so callers know concurrency characteristics
- [ ] Use `@moduledoc` to explain the resource lifecycle (create → use → let GC collect)

```elixir
defmodule MyApp.Native do
  use Zig,
    otp_app: :my_app,
    optimize: :fast,
    zig_code_path: "./native/main.zig",
    nifs: [
      parse: [:dirty_cpu],
    ]

  @doc "Parse CSV into rows. Runs on dirty CPU scheduler."
  @spec parse(binary()) :: [[binary()]]
  def parse(_csv), do: :erlang.nif_error(:nif_not_loaded)
end
```

---

## 15. Testing Strategy

- [ ] Test NIF functions through Elixir — the wrapper is the public API
- [ ] Test safety: malformed input, empty input, nil, extremely large input
- [ ] Test concurrent access: spawn many processes hitting the same resource simultaneously
- [ ] Test resource cleanup: create and discard many resources, check for memory leaks with `:erlang.memory()`
- [ ] Build with `optimize: :safe` in test to catch bounds violations and undefined behavior
- [ ] Enable `leak_check: true` per-function in tests to detect Zig memory leaks
- [ ] Zig-side unit tests via `zig test` for pure logic that doesn't touch BEAM types
- [ ] Property-based tests with `StreamData` for input fuzzing

---

## 16. Anti-Patterns to Avoid

| Anti-Pattern | Why It's Dangerous |
|---|---|
| `@panic` in NIF code | Crashes the entire BEAM VM — no supervisor recovery |
| `unreachable` for "shouldn't happen" cases | UB in release mode, crash in debug — use error tuples |
| Storing `beam.term` in resources | Terms are bound to a single NIF call's environment |
| Creating atoms from user input | Atom table exhaustion — atoms are never GC'd |
| Global mutable state (`var` at file scope) | Breaks BEAM process isolation |
| Heavy work on normal schedulers | Blocks all Erlang processes on that scheduler |
| Holding Mutex locks while building large term trees | Starves concurrent access |
| `deinit` that does I/O | Cleanup timing is GC-driven; I/O can delay or fail |
| Manual memory management from Elixir | Defeats BEAM GC integration |
| Array indexing without bounds checks in release mode | Silent memory corruption in `:fast` mode |
| `Enum.map(results, &Native.nif/1)` loops | N boundary crossings — push the loop into a batch NIF |
| Converting Zig struct → BEAM terms → back to Zig | Serialization roundtrip — use Resource to keep data in Zig |
| Filtering NIF results with `Enum.filter` | Materializes all items just to discard some — filter in Zig |
| `:dirty_cpu` on tiny operations | Dirty scheduler handoff overhead dominates |
| Returning thousands of small binaries | BEAM binary creation overhead per item — return one binary, split in Elixir |
| Missing `beam.yield()` in threaded NIFs | Process can't be killed; resource leaks on process termination |
| Forgetting `__resource__.keep/release` in threaded NIFs | Use-after-free segfault |

---

## 17. Data Pipeline Design — Maximize Zig, Minimize Roundtrips

The biggest performance mistake in NIF design is treating Zig as a utility function library called from Elixir loops. Every boundary crossing has cost. Push entire pipelines into Zig and only cross the boundary for input and final output.

### Keep the Hot Path Entirely in Zig

- [ ] **Never parse in Elixir then re-parse in Zig** — send the raw binary and do all parsing in Zig
- [ ] **Never transform in Elixir between NIF calls** — compose operations in a single NIF
- [ ] **If Elixir is looping over NIF results to call another NIF per item, that's a design smell** — provide a batch NIF or push the loop into Zig

```elixir
# BAD: N+1 boundary crossings
doc = Native.parse(csv)
rows = Enum.map(doc, fn row -> Native.process_row(row) end)  # N crossings!

# GOOD: single boundary crossing
rows = Native.parse_and_process(csv)  # 1 crossing
```

### Avoid Redundant Serialization

- [ ] **Don't convert Zig structs to Elixir terms just to pass them back into another NIF** — use `beam.Resource` to keep intermediate state in Zig
- [ ] **Don't round-trip through Elixir maps when Zig has the data** — accessing a Zig struct behind a resource is O(1) via a targeted accessor NIF

### Push Filtering, Mapping, and Aggregation into Zig

- [ ] **Filters belong in Zig** — `Enum.filter` on NIF results means you materialized N items across the boundary only to throw some away
- [ ] **Map/transform belongs in Zig** — do it before crossing the boundary
- [ ] **Aggregation belongs in Zig** — counting, summing, min/max — all cheaper in Zig
- [ ] **Sorting belongs in Zig** — `std.sort` is cache-friendly; crossing the boundary to use `Enum.sort` wastes the performance advantage

### Algorithmic Efficiency in Zig

- [ ] **Use `std.HashMap` or `std.ArrayHashMap` for O(1) lookups** — don't iterate a slice to find a value
- [ ] **Pre-build indexes in the parse step** — hash indexes during parsing make queries O(1) not O(n)
- [ ] **Use arena allocation patterns** — a flat `[]T` with index-based references beats per-node allocation for cache locality
- [ ] **Avoid repeated allocations in hot loops** — pre-allocate `ArrayList` capacity, reuse buffers with `clearRetainingCapacity()`
- [ ] **Use `@Vector` SIMD for byte scanning** — Zig's built-in SIMD is zero-cost and portable
- [ ] **Prefer slices over allocated arrays** — `[]const u8` views avoid copies when the source data outlives the operation

### Zero-Copy When Possible

- [ ] **`[]const u8` input from Zigler is a view into BEAM memory** — no copy needed for read-only access within a single NIF call
- [ ] **Use slices and pointers within a single NIF call** — data that doesn't escape the NIF lifetime doesn't need to be owned
- [ ] **For output, `beam.make(slice, .{})` copies into BEAM memory** — this is the correct transfer mechanism
- [ ] **Operate on `[]const u8` byte slices and only validate UTF-8 at the boundary if needed**

### Design NIF APIs for Minimal Crossings

- [ ] **Parse-once, query-many pattern** — parse into a `beam.Resource`, then run N queries without re-parsing
- [ ] **Lazy result sets** — return a resource pointing to matched results; let Elixir pull on demand
- [ ] **Batch accessors** — `get_texts(resource, 0, 100)` instead of 100 calls to `get_text(resource, i)`
- [ ] **Compound operations** — `parse_and_query(csv, filter)` for one-shot use cases
- [ ] **Extract operations** — a single `extract(resource, start, count)` NIF that returns exactly what's needed, built entirely in Zig

### Know Where the Time Actually Goes

- [ ] **Profile before optimizing** — the bottleneck is often `beam.make` term construction, not Zig computation
- [ ] **NIF call overhead is measurable** — batch calls to amortize it
- [ ] **Dirty scheduler handoff has overhead** — don't use `:dirty_cpu` for trivial operations
- [ ] **BEAM binary creation has overhead** — returning 10,000 small binaries is slower than one large binary that Elixir splits
- [ ] **Mutex contention shows up at scale** — profile under realistic concurrency

---

## Quick Reference: NIF Scheduling Decision Tree

```
Is the work < 1ms in the worst case?
├─ Yes → Normal scheduler (default, no option needed)
└─ No → Is it CPU-bound or I/O-bound?
    ├─ CPU-bound → nifs: [my_fn: [:dirty_cpu]]
    ├─ I/O-bound → nifs: [my_fn: [:dirty_io]]
    └─ Long-running with message passing → nifs: [my_fn: [:threaded]]
```

## Quick Reference: Return Type Decision Tree

```
Is this a one-shot computation?
├─ Yes → Return the result directly via beam.make
└─ No → Will the caller access the result multiple times?
    ├─ Yes → Return a beam.Resource (lazy access pattern)
    └─ No → Return a batch result (list/map of values)
```

## Quick Reference: Where Should This Work Happen?

```
Does this operation touch data that's already in Zig (behind a Resource)?
├─ Yes → Do it in Zig. Don't pull data to Elixir just to push it back.
└─ No → Is the input raw bytes (binary, file contents, network payload)?
    ├─ Yes → Send raw binary to Zig. Don't pre-process in Elixir.
    └─ No → Is it structured Elixir data (maps, keyword lists, etc.)?
        ├─ Yes, and it's small → Zigler auto-marshals maps/structs
        └─ Yes, and it's large → Consider encoding to binary first

Is Elixir calling a NIF in a loop?
├─ Yes, over NIF results → Batch NIF or push the loop into Zig
├─ Yes, over Elixir data → Consider a single NIF that takes a list
└─ No → Single NIF call is fine

Is Elixir filtering/mapping/sorting NIF results?
├─ Yes → Move that logic into Zig — filter/map/sort before crossing the boundary
└─ No → Elixir pipeline is appropriate for orchestration, not data transformation
```
