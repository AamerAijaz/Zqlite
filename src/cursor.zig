const std = @import("std");
const pager = @import("pager.zig");
const btree = @import("btree.zig");
const Row = @import("statement.zig").Row;

pub const Cursor = struct {
    btree: btree.Btree,
    page: u32,
    cell: u32,
    end_of_table: bool,

    pub fn insert(self: *Cursor, row: *const Row) !void {
        const key = row.id;
        try self.btree.add(key, std.mem.asBytes(row));
    }

    pub fn select(self: *Cursor, _: *std.Io.Writer) !void {
        const start_record = self.btree.find(0);
        try self.set_position(start_record.page, start_record.cell);

        while (self.end_of_table != true) {
            const row = try self.value();
            std.debug.print("Row - id: {d}, user: {s}, email: {s}\n", .{
                row.?.id,
                row.?.username,
                row.?.email,
            });
            try self.advance();
        }
    }

    pub fn value(self: *Cursor) !?Row {
        if (self.end_of_table) {
            return null;
        }

        const buf = try self.btree.get(self.page, self.cell);
        const row = std.mem.bytesToValue(Row, buf);
        return row;
    }

    pub fn set_position(self: *Cursor, page: u32, cell: u32) !void {
        self.page = page;
        self.cell = cell;

        const max_record = try self.btree.get_max_cell();
        self.end_of_table = self.btree.empty or (page == max_record.page) and (cell == max_record.cell + 1);
    }

    /// Advances the cursor's position.
    /// Assumes that the cursor currently points to a leaf node.
    pub fn advance(self: *Cursor) !void {
        const node = try self.btree.get_node(self.page);
        switch (node) {
            .Leaf => {
                const leaf_node = node.Leaf;
                const num_cells = leaf_node.get_num_cells();
                if (self.cell >= num_cells) {
                    try self.set_position(leaf_node.get_next_node(), 0);
                } else {
                    try self.set_position(self.page, self.cell + 1);
                }
            },
            .Internal => {},
        }
    }

    pub fn deinit(self: *Cursor) void {
        self.btree.pager.deinit();
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Cursor {
    var tree = try btree.init(io, allocator, file);
    const max_record = try tree.get_max_cell();
    return Cursor{
        .btree = tree,
        .cell = 0,
        .page = 0,
        .end_of_table = tree.empty or (max_record.page == 0) and (max_record.cell == 1),
    };
}
