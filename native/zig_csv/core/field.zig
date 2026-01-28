const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types");
const scanner = @import("scanner");

const Config = types.Config;
const FieldBoundary = types.FieldBoundary;

/// Unescape a quoted field: remove doubled escape sequences.
/// For single-byte escape (e.g. " -> ""): removes one of each doubled byte.
/// For multi-byte escape (e.g. '' -> ''''): removes one copy of each doubled pattern.
pub fn unescapeField(input: []const u8, config: *const Config, output: []u8) usize {
    std.debug.assert(input.len <= output.len);
    const esc = config.getEscape();
    const esc_len = esc.len;

    if (esc_len == 1) {
        // Fast path: single-byte escape
        return unescapeSingleByte(input, esc[0], output);
    }

    // Multi-byte escape path
    var write_idx: usize = 0;
    var read_idx: usize = 0;

    while (read_idx < input.len) {
        if (read_idx + esc_len * 2 <= input.len and
            std.mem.eql(u8, input[read_idx..][0..esc_len], esc) and
            std.mem.eql(u8, input[read_idx + esc_len ..][0..esc_len], esc))
        {
            // Doubled escape -> output one copy
            @memcpy(output[write_idx..][0..esc_len], esc);
            write_idx += esc_len;
            read_idx += esc_len * 2;
        } else {
            output[write_idx] = input[read_idx];
            write_idx += 1;
            read_idx += 1;
        }
    }

    return write_idx;
}

/// Legacy single-byte unescape (also used by engine fast path)
pub fn unescapeSingleByte(input: []const u8, escape: u8, output: []u8) usize {
    std.debug.assert(input.len <= output.len);
    var write_idx: usize = 0;
    var read_idx: usize = 0;

    while (read_idx < input.len) {
        if (input[read_idx] == escape and read_idx + 1 < input.len and input[read_idx + 1] == escape) {
            output[write_idx] = escape;
            write_idx += 1;
            read_idx += 2;
        } else {
            output[write_idx] = input[read_idx];
            write_idx += 1;
            read_idx += 1;
        }
    }

    return write_idx;
}

// Backward-compatible wrapper
pub fn unescapeInPlace(input: []const u8, escape: u8, output: []u8) usize {
    return unescapeSingleByte(input, escape, output);
}
