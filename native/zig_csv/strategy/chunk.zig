const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types");
const scanner = @import("scanner");
const memory = @import("memory");
const fast = @import("fast");
const field_mod = @import("field");
const engine_mod = @import("engine");
const row_collector = @import("row_collector");

const Config = types.Config;
const allocator = memory.allocator;

pub fn parseChunk(input: []const u8, config: Config) struct { beam.term, usize } {
    if (input.len == 0) {
        return .{ beam.make(&[_]beam.term{}, .{}), 0 };
    }

    // Find last complete row boundary (quote-aware)
    const last_complete = engine_mod.findLastCompleteRow(input, config);

    // No complete rows found
    if (last_complete == 0) {
        return .{ beam.make(&[_]beam.term{}, .{}), 0 };
    }

    // Parse complete rows using fast parser
    const complete_data = input[0..last_complete];
    const rows = fast.parseCSVFast(complete_data, config);

    return .{ rows, last_complete };
}

// SIMD-accelerated version - now uses shared engine
pub fn parseChunkSimd(input: []const u8, config: Config) struct { beam.term, usize } {
    if (input.len == 0) {
        return .{ beam.make(&[_]beam.term{}, .{}), 0 };
    }

    var emitter = ChunkEmitter{};
    defer emitter.deinit();
    return engine_mod.ParseEngine(ChunkEmitter).parse(input, config, &emitter);
}

const ChunkEmitter = struct {
    collector: row_collector.RowCollector = .{},
    fields: std.ArrayListUnmanaged(beam.term) = .{},
    unescape_buf: [65536]u8 = undefined,
    last_row_end: usize = 0,
    current_pos: usize = 0,

    pub const Result = struct { beam.term, usize };

    pub fn canAddField(_: *ChunkEmitter) bool {
        return true;
    }

    pub fn onField(self: *ChunkEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
        const raw = input[start..end];

        const term = if (!needs_unescape) blk: {
            break :blk beam.make(raw, .{});
        } else if (raw.len <= self.unescape_buf.len) blk: {
            const len = field_mod.unescapeField(raw, config, &self.unescape_buf);
            break :blk beam.make(self.unescape_buf[0..len], .{});
        } else blk: {
            // Field exceeds stack buffer — heap-allocate for unescape
            const heap_buf = memory.allocator.alloc(u8, raw.len) catch {
                self.collector.oom_occurred = true;
                return;
            };
            defer memory.allocator.free(heap_buf);
            const len = field_mod.unescapeField(raw, config, heap_buf);
            break :blk beam.make(heap_buf[0..len], .{});
        };

        self.fields.append(memory.allocator, term) catch {
            self.collector.oom_occurred = true;
            self.current_pos = end;
            return;
        };
        self.current_pos = end;
    }

    pub fn onRowEnd(self: *ChunkEmitter, _: bool) void {
        if (self.fields.items.len > 0) {
            const field_list = row_collector.buildFieldList(self.fields.items, self.fields.items.len);
            self.collector.addRow(field_list);
            self.last_row_end = self.current_pos;
        }
        self.fields.clearRetainingCapacity();
    }

    pub fn finish(self: *ChunkEmitter) Result {
        // ChunkEmitter is used for streaming — don't raise on errors,
        // just return rows as-is.
        return .{ self.collector.buildList(), self.last_row_end };
    }

    pub fn deinit(self: *ChunkEmitter) void {
        self.fields.deinit(memory.allocator);
        self.collector.deinit();
    }
};
