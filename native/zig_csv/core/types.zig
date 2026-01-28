const std = @import("std");

pub const MAX_SEPS = 8;
pub const MAX_SEP_LEN = 16;
pub const MAX_ESC_LEN = 16;

pub const Config = struct {
    // Separator storage: up to 8 patterns, each up to 16 bytes
    seps: [MAX_SEPS][MAX_SEP_LEN]u8 = undefined,
    sep_lens: [MAX_SEPS]u8 = .{0} ** MAX_SEPS,
    sep_count: u8 = 0,

    // Escape storage: single pattern up to 16 bytes
    esc: [MAX_ESC_LEN]u8 = undefined,
    esc_len: u8 = 0,

    pub fn isSingleByteSep(self: Config) bool {
        return self.sep_count == 1 and self.sep_lens[0] == 1;
    }

    pub fn isSingleByteEsc(self: Config) bool {
        return self.esc_len == 1;
    }

    /// Returns length of matched separator at pos, or null
    pub fn matchSepAt(self: Config, input: []const u8, pos: usize) ?usize {
        var s: u8 = 0;
        while (s < self.sep_count) : (s += 1) {
            const len = self.sep_lens[s];
            if (pos + len <= input.len) {
                if (std.mem.eql(u8, input[pos..][0..len], self.seps[s][0..len])) {
                    return len;
                }
            }
        }
        return null;
    }

    /// Returns length of escape pattern if it matches at pos, or null
    pub fn matchEscAt(self: Config, input: []const u8, pos: usize) ?usize {
        if (self.esc_len == 0) return null;
        const len = self.esc_len;
        if (pos + len > input.len) return null;
        if (std.mem.eql(u8, input[pos..][0..len], self.esc[0..len])) {
            return len;
        }
        return null;
    }

    /// Get the escape pattern as a slice
    pub fn getEscape(self: *const Config) []const u8 {
        return self.esc[0..self.esc_len];
    }

    /// Get separator pattern i as a slice
    pub fn getSep(self: *const Config, i: u8) []const u8 {
        return self.seps[i][0..self.sep_lens[i]];
    }

    /// Get the single separator byte (fast path only - caller must check isSingleByteSep)
    pub fn sepByte(self: Config) u8 {
        return self.seps[0][0];
    }

    /// Get the single escape byte (fast path only - caller must check isSingleByteEsc)
    pub fn escByte(self: Config) u8 {
        return self.esc[0];
    }

    /// Collect unique first bytes of all separators (for SIMD first-byte filter)
    pub fn sepFirstBytes(self: Config) struct { bytes: [MAX_SEPS]u8, count: u8 } {
        var result: [MAX_SEPS]u8 = undefined;
        var count: u8 = 0;
        var s: u8 = 0;
        while (s < self.sep_count) : (s += 1) {
            const fb = self.seps[s][0];
            // Deduplicate
            var found = false;
            var j: u8 = 0;
            while (j < count) : (j += 1) {
                if (result[j] == fb) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                result[count] = fb;
                count += 1;
            }
        }
        return .{ .bytes = result, .count = count };
    }

    /// Decode from NIF binary parameters.
    /// sep_data format: <<count::8, len1::8, sep1::binary-size(len1), ...>>
    /// esc_data format: raw escape string bytes
    pub fn fromEncoded(sep_data: []const u8, esc_data: []const u8) ?Config {
        var config = Config{};

        // Decode separators
        if (sep_data.len < 1) return null;
        const count = sep_data[0];
        if (count == 0 or count > MAX_SEPS) return null;
        config.sep_count = count;

        var offset: usize = 1;
        var s: u8 = 0;
        while (s < count) : (s += 1) {
            if (offset >= sep_data.len) return null;
            const len = sep_data[offset];
            offset += 1;
            if (len == 0 or len > MAX_SEP_LEN) return null;
            if (offset + len > sep_data.len) return null;
            @memcpy(config.seps[s][0..len], sep_data[offset..][0..len]);
            config.sep_lens[s] = len;
            offset += len;
        }

        // Decode escape
        if (esc_data.len == 0 or esc_data.len > MAX_ESC_LEN) return null;
        @memcpy(config.esc[0..esc_data.len], esc_data);
        config.esc_len = @intCast(esc_data.len);

        return config;
    }

    /// Convenience constructor for single-byte separator and escape (backward compat)
    pub fn singleByte(sep: u8, esc: u8) Config {
        var config = Config{};
        config.seps[0][0] = sep;
        config.sep_lens[0] = 1;
        config.sep_count = 1;
        config.esc[0] = esc;
        config.esc_len = 1;
        return config;
    }
};

pub const FieldBoundary = packed struct {
    start: u32,
    end: u32,
    needs_unescape: bool,
};
