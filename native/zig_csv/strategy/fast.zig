const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types");
const scanner = @import("scanner");
const field_mod = @import("field");
const memory = @import("memory");
const engine = @import("engine");
const row_collector = @import("row_collector");

const Config = types.Config;

const FastEmitter = struct {
    collector: row_collector.RowCollector = .{},
    field_buf: [row_collector.MAX_FIELDS]beam.term = undefined,
    unescape_buf: [65536]u8 = undefined,
    field_count: usize = 0,

    pub const Result = beam.term;

    pub fn canAddField(self: *FastEmitter) bool {
        return self.field_count < self.field_buf.len;
    }

    pub fn onField(self: *FastEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
        const raw = input[start..end];

        if (needs_unescape) {
            const len = field_mod.unescapeField(raw, config, &self.unescape_buf);
            self.field_buf[self.field_count] = beam.make(self.unescape_buf[0..len], .{});
        } else {
            self.field_buf[self.field_count] = beam.make(raw, .{});
        }
        self.field_count += 1;
    }

    pub fn onRowEnd(self: *FastEmitter, _: bool) void {
        if (self.field_count > 0) {
            const field_list = row_collector.buildFieldList(&self.field_buf, self.field_count);
            self.collector.addRow(field_list);
        }
        self.field_count = 0;
    }

    pub fn finish(self: *FastEmitter) beam.term {
        return self.collector.buildList();
    }
};

pub fn parseCSVFast(input: []const u8, config: Config) beam.term {
    var emitter = FastEmitter{};
    defer emitter.collector.deinit();
    return engine.ParseEngine(FastEmitter).parse(input, config, &emitter);
}
