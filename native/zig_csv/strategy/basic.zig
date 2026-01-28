const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const types = @import("types");
const scanner = @import("scanner");
const memory = @import("memory");
const field = @import("field");
const fast = @import("fast");

const Config = types.Config;

// Basic parser now delegates to fast parser (scanner already has scalar fallback)
pub fn parseCSVBasic(input: []const u8, config: Config) beam.term {
    return fast.parseCSVFast(input, config);
}
