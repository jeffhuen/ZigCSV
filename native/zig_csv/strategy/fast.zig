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
    fields: std.ArrayListUnmanaged(beam.term) = .{},
    unescape_buf: [65536]u8 = undefined,
    unterminated_quote: bool = false,
    mid_field_escape: bool = false,
    error_byte_pos: usize = 0,

    pub const Result = beam.term;

    pub fn canAddField(_: *FastEmitter) bool {
        return true;
    }

    pub fn onUnterminatedQuote(self: *FastEmitter) void {
        self.unterminated_quote = true;
    }

    pub fn onMidFieldEscape(self: *FastEmitter, pos: usize) void {
        self.mid_field_escape = true;
        self.error_byte_pos = pos;
    }

    pub fn onField(self: *FastEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
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
            return;
        };
    }

    pub fn onRowEnd(self: *FastEmitter, _: bool) void {
        if (self.fields.items.len > 0) {
            const field_list = row_collector.buildFieldList(self.fields.items, self.fields.items.len);
            self.collector.addRow(field_list);
        }
        self.fields.clearRetainingCapacity();
    }

    pub fn finish(self: *FastEmitter) beam.term {
        if (self.collector.oom_occurred or self.unterminated_quote or self.mid_field_escape) {
            const tag = if (self.unterminated_quote)
                beam.make(.unterminated_escape, .{})
            else if (self.mid_field_escape)
                beam.make(.{ .unexpected_escape, self.error_byte_pos }, .{})
            else
                beam.make(.oom, .{});
            return beam.make(.{ .partial, tag, self.collector.buildList() }, .{});
        }
        return self.collector.buildList();
    }

    pub fn deinit(self: *FastEmitter) void {
        self.fields.deinit(memory.allocator);
        self.collector.deinit();
    }
};

pub fn parseCSVFast(input: []const u8, config: Config) beam.term {
    var emitter = FastEmitter{};
    defer emitter.deinit();
    return engine.ParseEngine(FastEmitter).parse(input, config, &emitter);
}
