const std = @import("std");
const pager = @import("pager.zig");
const btree = @import("btree.zig");

pub const CursorError = btree.BtreeError;

pub const Cursor = struct {
    btree: btree.Btree,

    pub fn deinit(self: *Cursor) void {
        self.btree.pager.deinit();
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Cursor {
    const tree = try btree.init(io, allocator, file);
    return Cursor{
        .btree = tree,
    };
}
