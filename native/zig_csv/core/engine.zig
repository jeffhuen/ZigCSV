const std = @import("std");
const beam = @import("beam");
const types = @import("types");
const scanner = @import("scanner");
const field_mod = @import("field");
const row_collector = @import("row_collector");

const Config = types.Config;

/// Generic parse engine parameterized over an Emitter type.
/// The Emitter handles what to do with each field and row.
///
/// Emitter interface:
///   fn onField(self, input, start, end, needs_unescape, config) void
///   fn onRowEnd(self, is_complete) void
///   fn finish(self) Emitter.Result
pub fn ParseEngine(comptime Emitter: type) type {
    return struct {
        pub fn parse(input: []const u8, config: Config, emitter: *Emitter) Emitter.Result {
            if (input.len == 0) {
                return emitter.finish();
            }

            var pos: usize = 0;

            while (pos <= input.len) {
                var row_done = false;

                // Parse fields in this row
                while (!row_done) {
                    if (!emitter.canAddField()) break;

                    if (pos < input.len and config.matchEscAt(input, pos) != null) {
                        // Quoted field
                        const esc_len = config.esc_len;
                        pos += esc_len;
                        const content_start = pos;
                        var needs_unescape = false;

                        // Find closing escape
                        if (config.isSingleByteEsc()) {
                            // Fast path: single-byte escape, use SIMD
                            const esc_byte = config.escByte();
                            while (pos < input.len) {
                                const remaining = input[pos..];
                                if (scanner.simdFindByte(remaining, esc_byte)) |offset| {
                                    pos += offset + 1;
                                    if (pos < input.len and input[pos] == esc_byte) {
                                        needs_unescape = true;
                                        pos += 1;
                                    } else {
                                        break;
                                    }
                                } else {
                                    pos = input.len;
                                    break;
                                }
                            }
                        } else {
                            // Multi-byte escape path
                            const esc = config.getEscape();
                            while (pos < input.len) {
                                const remaining = input[pos..];
                                if (scanner.findPattern(remaining, esc)) |offset| {
                                    pos += offset + esc_len;
                                    if (scanner.matchAt(input, pos, esc)) {
                                        needs_unescape = true;
                                        pos += esc_len;
                                    } else {
                                        break;
                                    }
                                } else {
                                    pos = input.len;
                                    break;
                                }
                            }
                        }

                        const content_end = if (pos > content_start and pos >= esc_len) pos - esc_len else content_start;
                        emitter.onField(input, content_start, content_end, needs_unescape, &config);
                    } else {
                        // Unquoted field
                        const start = pos;
                        if (start < input.len) {
                            const remaining = input[start..];
                            if (scanner.findNextDelimiter(remaining, &config)) |delim| {
                                pos = start + delim.pos;
                            } else {
                                pos = input.len;
                            }
                            emitter.onField(input, start, pos, false, &config);
                        } else {
                            // Empty field at end of input
                            emitter.onField(input, start, start, false, &config);
                        }
                    }

                    // Check for separator or end of row
                    if (pos < input.len) {
                        if (config.matchSepAt(input, pos)) |sep_len| {
                            pos += sep_len;
                            // Continue to next field
                        } else if (input[pos] == '\r' or input[pos] == '\n') {
                            if (input[pos] == '\r') pos += 1;
                            if (pos < input.len and input[pos] == '\n') pos += 1;
                            row_done = true;
                        }
                    } else {
                        // End of input
                        row_done = true;
                    }
                }

                emitter.onRowEnd(true);

                // Exit if we've consumed all input
                if (pos >= input.len) break;
            }

            return emitter.finish();
        }
    };
}

/// Find the position of the last complete row boundary (quote-aware).
/// Returns 0 if no complete row found.
pub fn findLastCompleteRow(input: []const u8, config: Config) usize {
    var last_complete: usize = 0;
    var in_quotes = false;
    var scan_pos: usize = 0;

    const esc = config.getEscape();
    const esc_len = config.esc_len;
    const single_byte_esc = config.isSingleByteEsc();

    while (scan_pos < input.len) {
        if (single_byte_esc) {
            const c = input[scan_pos];
            if (c == esc[0]) {
                if (in_quotes and scan_pos + 1 < input.len and input[scan_pos + 1] == esc[0]) {
                    scan_pos += 2;
                    continue;
                }
                in_quotes = !in_quotes;
            } else if (!in_quotes and c == '\n') {
                last_complete = scan_pos + 1;
            } else if (!in_quotes and c == '\r') {
                if (scan_pos + 1 < input.len and input[scan_pos + 1] == '\n') {
                    last_complete = scan_pos + 2;
                    scan_pos += 1;
                } else {
                    last_complete = scan_pos + 1;
                }
            }
            scan_pos += 1;
        } else {
            // Multi-byte escape
            if (scanner.matchAt(input, scan_pos, esc)) {
                if (in_quotes and scanner.matchAt(input, scan_pos + esc_len, esc)) {
                    scan_pos += esc_len * 2;
                    continue;
                }
                in_quotes = !in_quotes;
                scan_pos += esc_len;
            } else if (!in_quotes and input[scan_pos] == '\n') {
                last_complete = scan_pos + 1;
                scan_pos += 1;
            } else if (!in_quotes and input[scan_pos] == '\r') {
                if (scan_pos + 1 < input.len and input[scan_pos + 1] == '\n') {
                    last_complete = scan_pos + 2;
                    scan_pos += 2;
                } else {
                    last_complete = scan_pos + 1;
                    scan_pos += 1;
                }
            } else {
                scan_pos += 1;
            }
        }
    }

    return last_complete;
}
