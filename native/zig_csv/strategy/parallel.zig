const std = @import("std");
const beam = @import("beam");
const types = @import("types");
const fast = @import("fast");

const Config = types.Config;

// Strategy E: Parallel Parser (currently delegates to fast parser)
pub fn parseCSVParallel(input: []const u8, config: Config) beam.term {
    return fast.parseCSVFast(input, config);
}
