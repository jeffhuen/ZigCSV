const std = @import("std");
const types = @import("types");

const Config = types.Config;

pub const VECTOR_SIZE = 32;
pub const CharVector = @Vector(VECTOR_SIZE, u8);
pub const MaskType = u32;

pub inline fn simdFindAny3(haystack: []const u8, a: u8, b: u8, c: u8) ?usize {
    var i: usize = 0;

    // Process 32 bytes at a time
    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: CharVector = haystack[i..][0..VECTOR_SIZE].*;
        const matches = (chunk == @as(CharVector, @splat(a))) |
            (chunk == @as(CharVector, @splat(b))) |
            (chunk == @as(CharVector, @splat(c)));

        if (@reduce(.Or, matches)) {
            const mask: MaskType = @bitCast(matches);
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    // Scalar fallback for remainder
    while (i < haystack.len) {
        const c_byte = haystack[i];
        if (c_byte == a or c_byte == b or c_byte == c) return i;
        i += 1;
    }

    return null;
}

pub inline fn simdFindByte(haystack: []const u8, target: u8) ?usize {
    var i: usize = 0;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: CharVector = haystack[i..][0..VECTOR_SIZE].*;
        const matches = chunk == @as(CharVector, @splat(target));

        if (@reduce(.Or, matches)) {
            const mask: MaskType = @bitCast(matches);
            return i + @ctz(mask);
        }
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) {
        if (haystack[i] == target) return i;
        i += 1;
    }

    return null;
}

pub inline fn simdCountByte(haystack: []const u8, target: u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i + VECTOR_SIZE <= haystack.len) {
        const chunk: CharVector = haystack[i..][0..VECTOR_SIZE].*;
        const matches = chunk == @as(CharVector, @splat(target));
        count += @popCount(@as(MaskType, @bitCast(matches)));
        i += VECTOR_SIZE;
    }

    while (i < haystack.len) {
        if (haystack[i] == target) count += 1;
        i += 1;
    }

    return count;
}

/// Check if input[pos..] starts with pattern.
pub inline fn matchAt(input: []const u8, pos: usize, pattern: []const u8) bool {
    if (pos + pattern.len > input.len) return false;
    return std.mem.eql(u8, input[pos..][0..pattern.len], pattern);
}

/// Find next position in haystack matching any separator, \r, or \n.
/// For single-byte separator: uses simdFindAny3 (fast path).
/// For multi-byte/multi-sep: SIMD first-byte filter + full match verification.
pub fn findNextDelimiter(haystack: []const u8, config: *const Config) ?struct { pos: usize, kind: DelimiterKind, len: usize } {
    if (config.isSingleByteSep()) {
        // Fast path: single-byte separator, use existing SIMD
        const sep = config.sepByte();
        if (simdFindAny3(haystack, sep, '\n', '\r')) |pos| {
            if (haystack[pos] == sep) {
                return .{ .pos = pos, .kind = .separator, .len = 1 };
            } else if (haystack[pos] == '\r') {
                return .{ .pos = pos, .kind = .newline, .len = if (pos + 1 < haystack.len and haystack[pos + 1] == '\n') @as(usize, 2) else @as(usize, 1) };
            } else {
                return .{ .pos = pos, .kind = .newline, .len = 1 };
            }
        }
        return null;
    }

    // General path: scan for first bytes of all separators + newline chars
    // Collect unique first bytes for SIMD filtering
    const fb = config.sepFirstBytes();

    var search_pos: usize = 0;
    while (search_pos < haystack.len) {
        // Find next candidate position using scalar scan for any first byte or newline
        var found: ?usize = null;
        var i: usize = search_pos;
        while (i < haystack.len) {
            const b = haystack[i];
            if (b == '\n' or b == '\r') {
                found = i;
                break;
            }
            var j: u8 = 0;
            while (j < fb.count) : (j += 1) {
                if (b == fb.bytes[j]) {
                    found = i;
                    break;
                }
            }
            if (found != null) break;
            i += 1;
        }

        if (found) |candidate| {
            const b = haystack[candidate];
            // Check newlines first
            if (b == '\r') {
                return .{ .pos = candidate, .kind = .newline, .len = if (candidate + 1 < haystack.len and haystack[candidate + 1] == '\n') @as(usize, 2) else @as(usize, 1) };
            }
            if (b == '\n') {
                return .{ .pos = candidate, .kind = .newline, .len = 1 };
            }
            // Check full separator match
            if (config.matchSepAt(haystack, candidate)) |sep_len| {
                return .{ .pos = candidate, .kind = .separator, .len = sep_len };
            }
            // Not a full match, advance past this byte
            search_pos = candidate + 1;
        } else {
            break;
        }
    }

    return null;
}

/// Find next occurrence of a multi-byte pattern using SIMD first-byte filter.
pub fn findPattern(haystack: []const u8, pattern: []const u8) ?usize {
    if (pattern.len == 0) return null;
    if (pattern.len == 1) return simdFindByte(haystack, pattern[0]);

    const first_byte = pattern[0];
    var search_pos: usize = 0;

    while (search_pos < haystack.len) {
        const remaining = haystack[search_pos..];
        if (simdFindByte(remaining, first_byte)) |offset| {
            const candidate = search_pos + offset;
            if (matchAt(haystack, candidate, pattern)) {
                return candidate;
            }
            search_pos = candidate + 1;
        } else {
            break;
        }
    }

    return null;
}

pub const DelimiterKind = enum {
    separator,
    newline,
};
