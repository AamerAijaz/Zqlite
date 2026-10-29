const std = @import("std");
const pager = @import("pager.zig");

pub const BtreeError = pager.PagerError;
pub const Btree = struct {
    pager: pager.Pager,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, database_file: std.Io.File) BtreeError!Btree {
    const p = try pager.init(io, allocator, database_file);
    return Btree{
        .pager = p,
    };
}
