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
    defer emitter.collector.deinit();
    return engine_mod.ParseEngine(ChunkEmitter).parse(input, config, &emitter);
}

const ChunkEmitter = struct {
    collector: row_collector.RowCollector = .{},
    field_buf: [row_collector.MAX_FIELDS]beam.term = undefined,
    unescape_buf: [65536]u8 = undefined,
    field_count: usize = 0,
    last_row_end: usize = 0,
    current_pos: usize = 0,

    pub const Result = struct { beam.term, usize };

    pub fn canAddField(self: *ChunkEmitter) bool {
        return self.field_count < self.field_buf.len;
    }

    pub fn onField(self: *ChunkEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
        const raw = input[start..end];

        if (needs_unescape) {
            const len = field_mod.unescapeField(raw, config, &self.unescape_buf);
            self.field_buf[self.field_count] = beam.make(self.unescape_buf[0..len], .{});
        } else {
            self.field_buf[self.field_count] = beam.make(raw, .{});
        }
        self.field_count += 1;
        self.current_pos = end;
    }

    pub fn onRowEnd(self: *ChunkEmitter, _: bool) void {
        if (self.field_count > 0) {
            const field_list = row_collector.buildFieldList(&self.field_buf, self.field_count);
            self.collector.addRow(field_list);
            self.last_row_end = self.current_pos;
        }
        self.field_count = 0;
    }

    pub fn finish(self: *ChunkEmitter) Result {
        return .{ self.collector.buildList(), self.last_row_end };
    }
};

// Helper functions kept for compatibility
pub fn countListLength(list: beam.term) usize {
    var count: usize = 0;
    var current = list;
    while (true) {
        const head, const tail = beam.get_list_cell(current, .{}) catch break;
        _ = head;
        count += 1;
        current = tail;
    }
    return count;
}

pub fn appendLists(list1: beam.term, list2: beam.term) beam.term {
    var items: [102400]beam.term = undefined;
    var count: usize = 0;

    var current = list1;
    while (count < items.len) {
        const head, const tail = beam.get_list_cell(current, .{}) catch break;
        items[count] = head;
        count += 1;
        current = tail;
    }

    current = list2;
    while (count < items.len) {
        const head, const tail = beam.get_list_cell(current, .{}) catch break;
        items[count] = head;
        count += 1;
        current = tail;
    }

    return beam.make(items[0..count], .{});
}
