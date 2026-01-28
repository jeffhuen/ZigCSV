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

const ZeroCopyEmitter = struct {
    collector: row_collector.RowCollector = .{},
    fields: std.ArrayListUnmanaged(beam.term) = .{},
    unescape_buf: [65536]u8 = undefined,
    unterminated_quote: bool = false,
    mid_field_escape: bool = false,
    error_byte_pos: usize = 0,
    // Stored during init for enif_make_sub_binary calls
    input_term_v: e.ErlNifTerm = undefined,
    env: ?*e.ErlNifEnv = null,

    pub const Result = beam.term;

    pub fn canAddField(_: *ZeroCopyEmitter) bool {
        return true;
    }

    pub fn onUnterminatedQuote(self: *ZeroCopyEmitter) void {
        self.unterminated_quote = true;
    }

    pub fn onMidFieldEscape(self: *ZeroCopyEmitter, pos: usize) void {
        self.mid_field_escape = true;
        self.error_byte_pos = pos;
    }

    pub fn onField(self: *ZeroCopyEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
        var term: beam.term = undefined;

        if (needs_unescape) {
            const raw = input[start..end];
            if (raw.len <= self.unescape_buf.len) {
                const len = field_mod.unescapeField(raw, config, &self.unescape_buf);
                term = beam.make(self.unescape_buf[0..len], .{});
            } else {
                // Field too large for unescape buffer — emit raw (doubled escapes remain).
                term = beam.make(raw, .{});
            }
        } else if (self.env) |env_ptr| {
            // Zero-copy sub-binary
            term = .{
                .v = e.enif_make_sub_binary(env_ptr, self.input_term_v, start, end - start),
            };
        } else {
            // Fallback: copy (should not happen in normal use)
            term = beam.make(input[start..end], .{});
        }

        self.fields.append(memory.allocator, term) catch {
            self.collector.oom_occurred = true;
            return;
        };
    }

    pub fn onRowEnd(self: *ZeroCopyEmitter, _: bool) void {
        if (self.fields.items.len > 0) {
            const field_list = row_collector.buildFieldList(self.fields.items, self.fields.items.len);
            self.collector.addRow(field_list);
        }
        self.fields.clearRetainingCapacity();
    }

    pub fn finish(self: *ZeroCopyEmitter) beam.term {
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

    pub fn deinit(self: *ZeroCopyEmitter) void {
        self.fields.deinit(memory.allocator);
        self.collector.deinit();
    }
};

/// Zero-copy parser that creates sub-binaries referencing the original input.
/// Uses the shared engine with a ZeroCopyEmitter that calls enif_make_sub_binary.
pub fn parseCSVZeroCopy(input_term: beam.term, config: Config) beam.term {
    const env = beam.context.env;

    // Get binary data
    var bin: e.ErlNifBinary = undefined;
    if (e.enif_inspect_binary(env.?, input_term.v, &bin) == 0) {
        return beam.make(.@"error", .{});
    }

    const input = bin.data[0..bin.size];
    if (input.len == 0) {
        return beam.make(&[_]beam.term{}, .{});
    }

    var emitter = ZeroCopyEmitter{};
    emitter.input_term_v = input_term.v;
    emitter.env = env;
    defer emitter.deinit();
    return engine.ParseEngine(ZeroCopyEmitter).parse(input, config, &emitter);
}
