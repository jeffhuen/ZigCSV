const std = @import("std");
const beam = @import("beam");

// Compile-time feature flag for memory tracking
// To enable: Set to true and recompile with `mix compile --force`
// When false (default), all tracking code is eliminated by dead code elimination,
// resulting in zero runtime overhead.
pub const memory_tracking_enabled = false;

pub var memory_current: usize = 0;
pub var memory_peak: usize = 0;

pub fn get_zig_memory() struct { usize, usize } {
    return .{ memory_current, memory_peak };
}

pub fn get_zig_memory_peak() usize {
    return memory_peak;
}

pub fn reset_zig_memory_stats() void {
    memory_current = 0;
    memory_peak = 0;
}

// Tracking allocator - only compiled when memory_tracking_enabled
pub const TrackingAllocator = struct {
    parent: std.mem.Allocator,

    pub fn getAllocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = trackingAlloc,
        .resize = trackingResize,
        .remap = trackingRemap,
        .free = trackingFree,
    };

    fn trackingAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, ptr_align, ret_addr);
        if (memory_tracking_enabled and result != null) {
            memory_current += len;
            if (memory_current > memory_peak) {
                memory_peak = memory_current;
            }
        }
        return result;
    }

    fn trackingResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        if (self.parent.rawResize(buf, buf_align, new_len, ret_addr)) {
            if (memory_tracking_enabled) {
                if (new_len > old_len) {
                    memory_current += (new_len - old_len);
                    if (memory_current > memory_peak) {
                        memory_peak = memory_current;
                    }
                } else {
                    memory_current -= (old_len - new_len);
                }
            }
            return true;
        }
        return false;
    }

    fn trackingFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (memory_tracking_enabled and memory_current >= buf.len) {
            memory_current -= buf.len;
        }
        self.parent.rawFree(buf, buf_align, ret_addr);
    }

    fn trackingRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.parent.rawRemap(buf, buf_align, new_len, ret_addr);
        if (memory_tracking_enabled and result != null) {
            if (new_len > old_len) {
                memory_current += (new_len - old_len);
                if (memory_current > memory_peak) {
                    memory_peak = memory_current;
                }
            } else {
                memory_current -= (old_len - new_len);
            }
        }
        return result;
    }
};

pub var tracking_allocator_instance = TrackingAllocator{ .parent = beam.allocator };
pub const allocator = tracking_allocator_instance.getAllocator();
