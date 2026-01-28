const std = @import("std");
const beam = @import("beam");
const memory = @import("memory");

const allocator = memory.allocator;

pub const STACK_ROWS = 102400;
pub const MAX_FIELDS = 1024;

pub const RowCollector = struct {
    stack_rows: [STACK_ROWS]beam.term = undefined,
    heap_rows: ?[]beam.term = null,
    heap_capacity: usize = 0,
    row_count: usize = 0,

    pub fn addRow(self: *RowCollector, row_term: beam.term) void {
        if (self.row_count < STACK_ROWS) {
            self.stack_rows[self.row_count] = row_term;
        } else {
            if (self.heap_rows == null) {
                self.heap_capacity = STACK_ROWS * 2;
                self.heap_rows = allocator.alloc(beam.term, self.heap_capacity) catch return;
                @memcpy(self.heap_rows.?[0..STACK_ROWS], &self.stack_rows);
            } else if (self.row_count >= self.heap_capacity) {
                const new_capacity = self.heap_capacity * 2;
                self.heap_rows = allocator.realloc(self.heap_rows.?, new_capacity) catch return;
                self.heap_capacity = new_capacity;
            }
            self.heap_rows.?[self.row_count] = row_term;
        }
        self.row_count += 1;
    }

    pub fn buildList(self: *RowCollector) beam.term {
        var row_list = beam.make_empty_list(.{});
        var i: usize = self.row_count;

        if (self.heap_rows) |heap| {
            while (i > 0) {
                i -= 1;
                row_list = beam.make_list_cell(heap[i], row_list, .{});
            }
        } else {
            while (i > 0) {
                i -= 1;
                row_list = beam.make_list_cell(self.stack_rows[i], row_list, .{});
            }
        }

        return row_list;
    }

    pub fn deinit(self: *RowCollector) void {
        if (self.heap_rows) |h| {
            allocator.free(h);
            self.heap_rows = null;
        }
    }
};

/// Build a cons-cell list from a field buffer
pub fn buildFieldList(field_buf: []const beam.term, count: usize) beam.term {
    var field_list = beam.make_empty_list(.{});
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        field_list = beam.make_list_cell(field_buf[i], field_list, .{});
    }
    return field_list;
}
