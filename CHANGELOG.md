# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Multi-separator support: `separator: [",", "|"]` splits fields on any listed pattern
- Multi-byte separator support: `separator: "||"` and mixed `separator: [",", "||"]`
- Multi-byte escape support: `escape: "''"` for non-standard quoting conventions
- Shared generic parse engine (`core/engine.zig`) eliminating duplicated parsing logic
- `RowCollector` module (`core/row_collector.zig`) for shared SmallVec row storage
- 12 new tests covering multi-separator, multi-byte separator, and multi-byte escape
- NIF robustness test suite: concurrent access, memory stability, and scheduler fairness tests
- `docs/NIF_PRACTICES.md` — Zigler-adapted NIF best practices checklist

### Changed

- All CPU-bound parse NIFs now run on dirty CPU schedulers (`:dirty_cpu`) to avoid blocking normal BEAM schedulers on large inputs
- Streaming resource creation (`streaming_new_with_config`, `streaming_new_encoded`) returns `{:error, :resource_alloc_failed}` on OOM instead of crashing the VM with `@panic`
- Memory tracking counters (`memory_current`, `memory_peak`) replaced with `std.atomic.Value(usize)` for thread-safe access across concurrent NIF calls
- Row count increment in `RowCollector.addRow` now saturates at `maxInt(usize)` and heap capacity doubling uses checked multiplication to prevent overflow
- `Config` struct now supports up to 8 separators (each up to 16 bytes) and escape up to 16 bytes
- Strategy files (`fast.zig`, `chunk.zig`, `zero_copy.zig`, `basic.zig`) rewritten as thin emitters using the shared engine
- NIF layer adds encoded config API (`parse_fast/3`, `parse_basic/3`, etc.) alongside legacy single-byte API
- Scanner module extended with `findNextDelimiter`, `findPattern`, and `matchAt` for multi-byte/multi-separator support
- Streaming module accepts encoded separator and escape binaries

## [0.1.0] - 2026-01-27

### Added

- Initial release
- Zig NIF for high-performance CSV parsing
- Drop-in replacement for NimbleCSV
- Full NimbleCSV API compatibility
