const std = @import("std");
const beam = @import("beam");

// Compile-time feature flag for memory tracking
// To enable: Set to true and recompile with `mix compile --force`
// When false (default), all tracking code is eliminated by dead code elimination,
// resulting in zero runtime overhead.
pub const memory_tracking_enabled = false;

// Atomic counters for thread-safe memory tracking across concurrent NIF calls.
// Multiple BEAM schedulers may invoke NIFs simultaneously on different OS threads.
var memory_current_atomic = std.atomic.Value(usize).init(0);
var memory_peak_atomic = std.atomic.Value(usize).init(0);

pub fn get_zig_memory() struct { usize, usize } {
    return .{
        memory_current_atomic.load(.monotonic),
        memory_peak_atomic.load(.monotonic),
    };
}

pub fn get_zig_memory_peak() usize {
    return memory_peak_atomic.load(.monotonic);
}

pub fn reset_zig_memory_stats() void {
    memory_current_atomic.store(0, .monotonic);
    memory_peak_atomic.store(0, .monotonic);
}

/// Atomically add to memory_current and update memory_peak if needed.
fn trackAdd(len: usize) void {
    const new = memory_current_atomic.fetchAdd(len, .monotonic) +% len;
    // Racy peak update is acceptable — monotonic is sufficient for approximate tracking.
    var peak = memory_peak_atomic.load(.monotonic);
    while (new > peak) {
        peak = memory_peak_atomic.cmpxchgWeak(peak, new, .monotonic, .monotonic) orelse break;
    }
}

/// Atomically subtract from memory_current.
fn trackSub(len: usize) void {
    _ = memory_current_atomic.fetchSub(len, .monotonic);
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
            trackAdd(len);
        }
        return result;
    }

    fn trackingResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        if (self.parent.rawResize(buf, buf_align, new_len, ret_addr)) {
            if (memory_tracking_enabled) {
                if (new_len > old_len) {
                    trackAdd(new_len - old_len);
                } else {
                    trackSub(old_len - new_len);
                }
            }
            return true;
        }
        return false;
    }

    fn trackingFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (memory_tracking_enabled) {
            trackSub(buf.len);
        }
        self.parent.rawFree(buf, buf_align, ret_addr);
    }

    fn trackingRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const result = self.parent.rawRemap(buf, buf_align, new_len, ret_addr);
        if (memory_tracking_enabled and result != null) {
            if (new_len > old_len) {
                trackAdd(new_len - old_len);
            } else {
                trackSub(old_len - new_len);
            }
        }
        return result;
    }
};

pub var tracking_allocator_instance = TrackingAllocator{ .parent = beam.allocator };
pub const allocator = tracking_allocator_instance.getAllocator();
