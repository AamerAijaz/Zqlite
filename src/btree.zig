const std = @import("std");
const pager = @import("pager.zig");
const Node = @import("node.zig").Node;
const BaseNode = @import("node.zig").BaseNode;
const LeafNode = @import("node.zig").LeafNode;
const NodeType = @import("node.zig").NodeType;
const NodeError = @import("node.zig").NodeError;

pub const AddError = error{NotImplemented};
pub const Record = struct { page: u32, cell: u32 };

pub const Btree = struct {
    pager: pager.Pager,
    root: Node,

    pub fn get_node(self: *Btree, index: u32) !Node {
        const page = try self.pager.get_page(index);
        var base = BaseNode.init(page, index);
        const node = switch (base.get_node_type()) {
            NodeType.Leaf => Node{ .Leaf = base.to_leaf() },
            NodeType.Internal => Node{ .Leaf = base.to_leaf() },
        };
        return node;
    }

    /// Find returns the index to the page and cell for the given key.
    /// The page returned will always be a leaf node.
    pub fn find(self: *Btree, key: u32) Record {
        const root = self.root;
        return switch (root) {
            .Leaf => Btree.find_leaf(root, key),
            .Internal => Btree.find_leaf(root, key),
        };
    }

    pub fn find_leaf(node: Node, key: u32) Record {
        var leaf_node = node.Leaf;
        var min_index: u32 = 0;
        var max_index: u32 = leaf_node.get_num_cells();
        const page_index = leaf_node.base.page_index;

        while (min_index != max_index) {
            const index = (min_index + max_index) / 2;
            const key_at_index = leaf_node.get_key(index);
            if (key_at_index == key) {
                return .{ .page = page_index, .cell = index };
            } else if (key_at_index > index) {
                max_index = index;
            } else {
                min_index = index + 1;
            }
        }

        return .{
            .page = page_index,
            .cell = min_index,
        };
    }

    pub fn add(self: *Btree, key: u32, buf: []const u8) !void {
        const record = self.find(key);
        const node = try self.get_node(record.page);
        var leaf = node.Leaf;

        if (record.cell >= LeafNode.MaxCells) {
            std.debug.print("Leaf Cell Splitting has to be implemented!\n", .{});
            return AddError.NotImplemented;
        }

        leaf.add_cell(key, buf);
    }

    pub fn get_max_cell(self: *Btree) !Record {
        const root = self.root;
        switch (root) {
            .Internal => {
                return AddError.NotImplemented;
            },
            .Leaf => {
                const node = root.Leaf;
                const num_cells = node.get_num_cells();
                return .{
                    .cell = if (num_cells == 0) num_cells else num_cells - 1,
                    .page = node.base.page_index,
                };
            },
        }
    }

    /// Returns the value stored for a leaf starting from the page and cell.
    pub fn get(self: *Btree, page: u32, cell: u32) ![]u8 {
        const node = try self.get_node(page);
        switch (node) {
            .Leaf => {
                var leaf_node = node.Leaf;
                if (cell >= leaf_node.get_num_cells()) {
                    return NodeError.NumCellsExceeded;
                }
                return leaf_node.get_cell_value(cell);
            },
            .Internal => {
                return AddError.NotImplemented;
            },
        }
    }
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, database_file: std.Io.File) !Btree {
    var p = try pager.init(io, allocator, database_file);
    var root: Node = undefined;

    const num_pages = p.num_pages;

    // Fetch the root node.
    // The root node will always be at page 0.
    const page = try p.get_page(0);
    var base = BaseNode.init(page, 0);

    // If the number of pages in the database file was previously 0.
    // Then initialize the root node to be a new leaf node.
    if (num_pages == 0) {
        root = Node{ .Leaf = base.to_leaf() };
        root.Leaf.set_next_node(0);
        root.Leaf.set_num_cells(0);
        root.Leaf.base.set_root(true);
    } else {
        const node = switch (base.get_node_type()) {
            NodeType.Leaf => Node{ .Leaf = base.to_leaf() },
            NodeType.Internal => Node{ .Leaf = base.to_leaf() },
        };
        root = node;
    }

    return Btree{
        .pager = p,
        .root = root,
    };
}
