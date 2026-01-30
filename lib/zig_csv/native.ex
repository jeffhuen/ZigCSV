defmodule ZigCSV.Native do
  @moduledoc """
  Low-level NIF bindings for CSV parsing.

  This module provides direct access to the Zig NIF functions. For normal use,
  prefer the higher-level `ZigCSV.RFC4180` or custom parsers defined with
  `ZigCSV.define/2`.

  ## Architecture

  The NIF layer is organized into core modules and strategy modules:

  **Core modules** (`native/zig_csv/core/`):

    * `types` - `Config` struct supporting multiple separators (up to 8, each up to 16 bytes)
      and multi-byte escape strings (up to 16 bytes)
    * `scanner` - SIMD-accelerated delimiter scanning via `@Vector(32, u8)` with
      multi-separator and multi-byte pattern support
    * `field` - Field unescaping with multi-byte escape support
    * `engine` - Shared generic parse engine parameterized over emitter types,
      eliminating duplicated parsing logic across strategies
    * `row_collector` - SmallVec-style row storage (stack-first, heap-spill)
      and cons-cell list building

  **Strategy modules** (`native/zig_csv/strategy/`):

    * `fast` - SIMD-accelerated parser (default `:simd` strategy)
    * `basic` - Delegates to fast (scanner has scalar fallback)
    * `zero_copy` - Sub-binary references via `enif_make_sub_binary`
    * `chunk` - Chunk parser for streaming (returns rows + bytes consumed)
    * `parallel` - Multi-threaded parser

  ## NIF Functions

  Each strategy exposes multiple NIF entry points:

    * Legacy single-byte API (e.g., `parse_string_fast_with_config/3`) for backward
      compatibility
    * Encoded config API (e.g., `parse_fast/3`) accepting length-prefixed separator
      binary and escape binary for multi-separator/multi-byte support

  The encoded separator format is `<<count::8, len1::8, sep1::binary-size(len1), ...>>`.
  Use `ZigCSV.encode_separators/1` to produce this format.
  """

  use Zig,
    otp_app: :zig_csv,
    optimize: :fast,
    resources: [:StreamingParserResource],
    zig_code_path: "./native/zig_csv/main.zig",
    nifs: [
      # --- CPU-bound parse NIFs: dirty_cpu to avoid blocking normal schedulers ---
      # Basic strategy
      parse_string: [:dirty_cpu],
      parse_string_with_config: [:dirty_cpu],
      parse_basic: [:dirty_cpu],
      # SIMD/fast strategy
      parse_string_fast: [:dirty_cpu],
      parse_string_fast_with_config: [:dirty_cpu],
      parse_fast: [:dirty_cpu],
      # Parallel strategy
      parse_string_parallel: [:dirty_cpu],
      parse_string_parallel_with_config: [:dirty_cpu],
      parse_parallel: [:dirty_cpu],
      # Zero-copy strategy
      parse_string_zero_copy: [:dirty_cpu],
      parse_string_zero_copy_with_config: [:dirty_cpu],
      parse_zero_copy: [:dirty_cpu],
      # Chunk parsers (used in streaming, can still be CPU-heavy on large chunks)
      parse_chunk: [:dirty_cpu],
      parse_chunk_with_config: [:dirty_cpu],
      parse_chunk_encoded: [:dirty_cpu],
      parse_chunk_simd: [:dirty_cpu],
      parse_chunk_simd_with_config: [:dirty_cpu],
      # Streaming feed/finalize invoke fast parser internally
      streaming_feed: [:dirty_cpu],
      streaming_finalize: [:dirty_cpu],
      # --- Normal scheduler: fast O(1) operations ---
      streaming_new: [],
      streaming_new_with_config: [],
      streaming_new_encoded: [],
      streaming_status: [],
      nif_loaded: [],
      get_zig_memory: [],
      get_zig_memory_peak: [],
      reset_zig_memory_stats: []
    ],
    extra_modules: [
      types: {"./native/zig_csv/core/types.zig", []},
      scanner: {"./native/zig_csv/core/scanner.zig", [:types]},
      memory: {"./native/zig_csv/memory.zig", [:beam]},
      row_collector: {"./native/zig_csv/core/row_collector.zig", [:beam, :memory]},
      field: {"./native/zig_csv/core/field.zig", [:beam, :erl_nif, :types, :scanner]},
      engine:
        {"./native/zig_csv/core/engine.zig", [:beam, :types, :scanner, :field, :row_collector]},
      fast:
        {"./native/zig_csv/strategy/fast.zig",
         [:beam, :erl_nif, :types, :scanner, :field, :memory, :engine, :row_collector]},
      basic:
        {"./native/zig_csv/strategy/basic.zig",
         [:beam, :erl_nif, :types, :scanner, :memory, :field, :fast]},
      chunk:
        {"./native/zig_csv/strategy/chunk.zig",
         [:beam, :erl_nif, :types, :scanner, :memory, :fast, :field, :engine, :row_collector]},
      zero_copy:
        {"./native/zig_csv/strategy/zero_copy.zig",
         [:beam, :erl_nif, :types, :scanner, :field, :memory, :engine, :row_collector]},
      parallel: {"./native/zig_csv/strategy/parallel.zig", [:beam, :types, :fast]}
    ]

  # ==========================================================================
  # Types
  # ==========================================================================

  @typedoc "Opaque reference to a streaming parser"
  @opaque parser_ref :: reference()

  @typedoc "A parsed row (list of field binaries)"
  @type row :: [binary()]

  @typedoc "Multiple parsed rows"
  @type rows :: [row()]
end
