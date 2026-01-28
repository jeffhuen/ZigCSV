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
    field_buf: [row_collector.MAX_FIELDS]beam.term = undefined,
    unescape_buf: [65536]u8 = undefined,
    field_count: usize = 0,
    // Stored during init for enif_make_sub_binary calls
    input_term_v: e.ErlNifTerm = undefined,
    env: ?*e.ErlNifEnv = null,

    pub const Result = beam.term;

    pub fn canAddField(self: *ZeroCopyEmitter) bool {
        return self.field_count < self.field_buf.len;
    }

    pub fn onField(self: *ZeroCopyEmitter, input: []const u8, start: usize, end: usize, needs_unescape: bool, config: *const Config) void {
        if (needs_unescape) {
            const raw = input[start..end];
            const len = field_mod.unescapeField(raw, config, &self.unescape_buf);
            self.field_buf[self.field_count] = beam.make(self.unescape_buf[0..len], .{});
        } else if (self.env) |env_ptr| {
            // Zero-copy sub-binary
            self.field_buf[self.field_count] = .{
                .v = e.enif_make_sub_binary(env_ptr, self.input_term_v, start, end - start),
            };
        } else {
            // Fallback: copy (should not happen in normal use)
            self.field_buf[self.field_count] = beam.make(input[start..end], .{});
        }
        self.field_count += 1;
    }

    pub fn onRowEnd(self: *ZeroCopyEmitter, _: bool) void {
        if (self.field_count > 0) {
            const field_list = row_collector.buildFieldList(&self.field_buf, self.field_count);
            self.collector.addRow(field_list);
        }
        self.field_count = 0;
    }

    pub fn finish(self: *ZeroCopyEmitter) beam.term {
        return self.collector.buildList();
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
    defer emitter.collector.deinit();
    return engine.ParseEngine(ZeroCopyEmitter).parse(input, config, &emitter);
}
