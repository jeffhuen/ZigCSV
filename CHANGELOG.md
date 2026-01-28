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

### Changed

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
