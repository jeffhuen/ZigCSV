const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types");
const scanner = @import("scanner");
const memory = @import("memory");
const field = @import("field");
const basic = @import("basic");
const fast = @import("fast");
const chunk = @import("chunk");
const zero_copy = @import("zero_copy");
const parallel = @import("parallel");
const engine = @import("engine");
const row_collector = @import("row_collector");

const Config = types.Config;

// ============================================================================
// Streaming Parser Resource (for stateful streaming across NIF calls)
// ============================================================================

pub const StreamingParserState = struct {
    buffer: std.ArrayListUnmanaged(u8),
    config: Config,

    const Self = @This();

    pub fn init(config: Config) Self {
        return Self{
            .buffer = std.ArrayListUnmanaged(u8){},
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(beam.allocator);
    }
};

pub const StreamingParserResource = beam.Resource(StreamingParserState, @import("root"), .{});

// ============================================================================
// Helper: decode config from encoded parameters or fall back to single-byte
// ============================================================================

fn decodeConfig(encoded_seps: []const u8, escape: []const u8) Config {
    return Config.fromEncoded(encoded_seps, escape) orelse Config.singleByte(',', '"');
}

fn legacyConfig(separator: u8, escape: u8) Config {
    return Config.singleByte(separator, escape);
}

// ============================================================================
// Memory NIF functions
// ============================================================================

pub fn get_zig_memory() struct { usize, usize } {
    return memory.get_zig_memory();
}

pub fn get_zig_memory_peak() usize {
    return memory.get_zig_memory_peak();
}

pub fn reset_zig_memory_stats() void {
    memory.reset_zig_memory_stats();
}

// ============================================================================
// Strategy A: Basic Parser
// ============================================================================

pub fn parse_string(input: []const u8) beam.term {
    return basic.parseCSVBasic(input, Config.singleByte(',', '"'));
}

pub fn parse_string_with_config(input: []const u8, separator: u8, escape: u8) beam.term {
    return basic.parseCSVBasic(input, legacyConfig(separator, escape));
}

pub fn parse_basic(input: []const u8, encoded_seps: []const u8, escape: []const u8) beam.term {
    return basic.parseCSVBasic(input, decodeConfig(encoded_seps, escape));
}

// ============================================================================
// Strategy B: SIMD Parser (optimized)
// ============================================================================

pub fn parse_string_fast(input: []const u8) beam.term {
    return fast.parseCSVFast(input, Config.singleByte(',', '"'));
}

pub fn parse_string_fast_with_config(input: []const u8, separator: u8, escape: u8) beam.term {
    return fast.parseCSVFast(input, legacyConfig(separator, escape));
}

pub fn parse_fast(input: []const u8, encoded_seps: []const u8, escape: []const u8) beam.term {
    return fast.parseCSVFast(input, decodeConfig(encoded_seps, escape));
}

// ============================================================================
// Strategy C: Indexed Parser (delegates to fast)
// ============================================================================

pub fn parse_string_indexed(input: []const u8) beam.term {
    return fast.parseCSVFast(input, Config.singleByte(',', '"'));
}

pub fn parse_string_indexed_with_config(input: []const u8, separator: u8, escape: u8) beam.term {
    return fast.parseCSVFast(input, legacyConfig(separator, escape));
}

// ============================================================================
// Strategy D: Streaming Parser (Resource-based)
// ============================================================================

pub fn streaming_new() StreamingParserResource {
    return streaming_new_with_config(',', '"');
}

pub fn streaming_new_with_config(separator: u8, escape: u8) StreamingParserResource {
    const state = StreamingParserState.init(legacyConfig(separator, escape));
    return StreamingParserResource.create(state, .{}) catch {
        @panic("Failed to create streaming parser resource");
    };
}

pub fn streaming_new_encoded(encoded_seps: []const u8, escape: []const u8) StreamingParserResource {
    const state = StreamingParserState.init(decodeConfig(encoded_seps, escape));
    return StreamingParserResource.create(state, .{}) catch {
        @panic("Failed to create streaming parser resource");
    };
}

// Returns tuple: {parsed_rows_list, buffer_size}
pub fn streaming_feed(parser: StreamingParserResource, input_chunk: []const u8) struct { beam.term, usize } {
    var state = parser.unpack();

    // Append chunk to buffer
    state.buffer.appendSlice(beam.allocator, input_chunk) catch {
        parser.update(state);
        return .{ beam.make(&[_]beam.term{}, .{}), state.buffer.items.len };
    };

    // Find last complete row using shared engine function
    const data = state.buffer.items;
    const last_complete = engine.findLastCompleteRow(data, state.config);

    // Parse complete rows and return immediately
    var result: beam.term = beam.make(&[_]beam.term{}, .{});

    if (last_complete > 0) {
        const complete_data = data[0..last_complete];
        result = fast.parseCSVFast(complete_data, state.config);

        // Remove parsed bytes from buffer
        const remaining_len = data.len - last_complete;
        if (remaining_len > 0) {
            std.mem.copyForwards(u8, state.buffer.items[0..remaining_len], data[last_complete..]);
        }
        state.buffer.shrinkRetainingCapacity(remaining_len);
    }

    // Persist state changes back to resource
    parser.update(state);
    return .{ result, state.buffer.items.len };
}

pub fn streaming_finalize(parser: StreamingParserResource) beam.term {
    var state = parser.unpack();

    var result: beam.term = beam.make(&[_]beam.term{}, .{});

    if (state.buffer.items.len > 0) {
        result = fast.parseCSVFast(state.buffer.items, state.config);
        state.buffer.clearRetainingCapacity();
    }

    parser.update(state);
    return result;
}

pub fn streaming_status(parser: StreamingParserResource) struct { usize, bool } {
    const state = parser.unpack();
    return .{
        state.buffer.items.len,
        state.buffer.items.len > 0,
    };
}

// ============================================================================
// Strategy G: Chunk Parser
// ============================================================================

pub fn parse_chunk(input: []const u8) struct { beam.term, usize } {
    return parse_chunk_with_config(input, ',', '"');
}

pub fn parse_chunk_with_config(input: []const u8, separator: u8, escape: u8) struct { beam.term, usize } {
    return chunk.parseChunk(input, legacyConfig(separator, escape));
}

pub fn parse_chunk_encoded(input: []const u8, encoded_seps: []const u8, escape: []const u8) struct { beam.term, usize } {
    return chunk.parseChunk(input, decodeConfig(encoded_seps, escape));
}

pub fn parse_chunk_simd(input: []const u8) struct { beam.term, usize } {
    return parse_chunk_simd_with_config(input, ',', '"');
}

pub fn parse_chunk_simd_with_config(input: []const u8, separator: u8, escape: u8) struct { beam.term, usize } {
    return chunk.parseChunkSimd(input, legacyConfig(separator, escape));
}

// ============================================================================
// Strategy E: Parallel Parser
// ============================================================================

pub fn parse_string_parallel(input: []const u8) beam.term {
    return parse_string_parallel_with_config(input, ',', '"');
}

pub fn parse_string_parallel_with_config(input: []const u8, separator: u8, escape: u8) beam.term {
    return parallel.parseCSVParallel(input, legacyConfig(separator, escape));
}

pub fn parse_parallel(input: []const u8, encoded_seps: []const u8, escape: []const u8) beam.term {
    return parallel.parseCSVParallel(input, decodeConfig(encoded_seps, escape));
}

// ============================================================================
// Strategy F: Zero-Copy Parser
// ============================================================================

pub fn parse_string_zero_copy(input: beam.term) beam.term {
    return parse_string_zero_copy_with_config(input, ',', '"');
}

pub fn parse_string_zero_copy_with_config(input: beam.term, separator: u8, escape: u8) beam.term {
    return zero_copy.parseCSVZeroCopy(input, legacyConfig(separator, escape));
}

pub fn parse_zero_copy(input: beam.term, encoded_seps: []const u8, escape: []const u8) beam.term {
    return zero_copy.parseCSVZeroCopy(input, decodeConfig(encoded_seps, escape));
}

// ============================================================================
// Test function
// ============================================================================

pub fn nif_loaded() bool {
    return true;
}
