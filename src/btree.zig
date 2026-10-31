const std = @import("std");
const pager = @import("pager.zig");
const Node = @import("node.zig").Node;
const BaseNode = @import("node.zig").BaseNode;
const LeafNode = @import("node.zig").LeafNode;
const InternalNode = @import("node.zig").InternalNode;
const NodeType = @import("node.zig").NodeType;
const NodeError = @import("node.zig").NodeError;

pub const AddError = error{NotImplemented};
pub const Record = struct { page: u32, cell: u32 };

pub const Btree = struct {
    pager: pager.Pager,
    root: Node,
    empty: bool,

    /// Returns the node for the page at the given index.
    /// If the page does not exist, then a new page of page_size is allocated.
    /// By default, a new node not present in the database file yet, is initialized as a leaf node.
    pub fn get_node(self: *Btree, index: u32) !Node {
        const is_new_node = self.empty or index >= self.pager.num_pages;
        const page = try self.pager.get_page(index);

        var base = BaseNode.init(page, index);
        if (is_new_node) {
            base.set_node_type(NodeType.Leaf);
            base.set_parent(BaseNode.InvalidPageNum);
            base.set_root(base.is_root());

            var leaf = base.to_leaf();
            leaf.set_next_node(BaseNode.InvalidPageNum);
            leaf.set_num_cells(0);

            return Node{ .Leaf = leaf };
        }

        const node = switch (base.get_node_type()) {
            NodeType.Leaf => Node{ .Leaf = base.to_leaf() },
            NodeType.Internal => Node{ .Internal = base.to_internal() },
        };
        return node;
    }

    /// Find returns the index to the page and cell for the given key.
    /// The page returned will always be a leaf node.
    pub fn find(self: *Btree, node: Node, key: u32) !Record {
        const record = switch (node) {
            .Leaf => Btree.find_leaf(node.Leaf, key),
            .Internal => {
                const record = Btree.find_internal(node.Internal, key);
                const page = node.Internal.get_key(record.cell);
                const next_node = try self.get_node(page);
                return self.find(next_node, key);
            },
        };
        return record;
    }

    pub fn find_leaf(leaf_node: LeafNode, key: u32) Record {
        var min_index: u32 = 0;
        var max_index: u32 = leaf_node.get_num_cells();
        const page_index = leaf_node.base.page_index;

        while (min_index != max_index) {
            const index = (min_index + max_index) / 2;

            const key_at_index = leaf_node.get_key(index);
            if (key_at_index == key) {
                return .{ .page = page_index, .cell = index };
            } else if (key_at_index > key) {
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

    pub fn find_internal(internal_node: InternalNode, key: u32) Record {
        var min_index: u32 = 0;
        var max_index: u32 = internal_node.get_num_cells();

        while (min_index != max_index) {
            const index = (min_index + max_index) / 2;

            const key_at_index = internal_node.get_key(index);
            if (key_at_index >= key) {
                max_index = index;
            } else {
                min_index = index + 1;
            }
        }

        return .{ .page = internal_node.base.page_index, .cell = min_index };
    }

    pub fn add(self: *Btree, key: u32, buf: []const u8) !void {
        const record = try self.find(self.root, key);
        const node = try self.get_node(record.page);
        var leaf = node.Leaf;

        if (leaf.get_num_cells() >= LeafNode.MaxCells) {
            try self.split_and_add(leaf, record, key, buf);
        } else {
            leaf.add_cell(record.cell, key, buf);
        }

        self.empty = false;
    }

    /// Splits a leaf node and adds a new cell to the appropraite node.
    /// The cell may be added to either the left or the right node.
    /// The resulting split may also split the parent of the leaf node.
    pub fn split_and_add(self: *Btree, leaf: LeafNode, record: Record, key: u32, buf: []const u8) !void {
        // Initialize a new leaf node to act as the right node.
        var left_node = leaf;
        var right_node = (try self.get_node(self.pager.get_unusued_page())).Leaf;

        // Split and add the new cell between the left and right nodes.
        var index: u32 = LeafNode.MaxCells;
        const mid_point = LeafNode.MaxCells / 2 + 1;
        while (index >= 0) : (index -= 1) {
            var destination_node = if (index >= mid_point) right_node else left_node;
            const destination_node_idx = (index % mid_point);
            if (index == record.cell) {
                destination_node.add_cell(@intCast(destination_node_idx), key, buf);
            } else if (index > record.cell) {
                const cell = try left_node.remove_cell(index - 1);
                destination_node.add_cell(@intCast(destination_node_idx), cell[0], cell[1]);
            } else {
                const cell = try left_node.remove_cell(index);
                destination_node.add_cell(@intCast(destination_node_idx), cell[0], cell[1]);
            }

            if (index == 0) break;
        }

        const parent_index = left_node.base.get_parent();
        var parent: InternalNode = undefined;
        if (parent_index == BaseNode.InvalidPageNum) {
            // If the parent node also does not exist, then a new node has to be created.
            // This should happen if and only if the leaf node is the root node as well.
            std.debug.assert(leaf.base.is_root() == true);
            left_node = (try self.get_node(self.pager.get_unusued_page())).Leaf;

            // Transfer the cells as well the leaft node from leaf to left_node.
            LeafNode.move_cells(left_node, leaf);

            // Reset the root to the new internal node parent.
            parent = InternalNode.from_leaf(leaf);
            self.root = Node{ .Internal = parent };

            // Set the next node of the left-node to be the right node.
            left_node.set_next_node(right_node.base.page_index);

            // Update the parents of the left and right nodes.
            left_node.base.set_parent(parent.base.page_index);
            right_node.base.set_parent(parent.base.page_index);

            // Update the parent's pointers
            parent.set_right_child_ptr(right_node.base.page_index);
            parent.set_num_cells(parent.get_num_cells() + 1);
            const left_max_key = left_node.get_key(left_node.get_num_cells() - 1);
            parent.add_cell(0, left_max_key, left_node.base.page_index);
        } else {
            return AddError.NotImplemented;
        }
    }

    pub fn print_leaf_constants(_: *const Btree) void {
        std.debug.print(
            "LeafNode constants:\n  CellSpace: {d}\n  MaxCells: {d}\n  RightSplitCount: {d}\n  LeafSplitCount: {d}\n",
            .{
                LeafNode.CellSpace,
                LeafNode.MaxCells,
                LeafNode.RightSplitCount,
                LeafNode.LeftSplitCount,
            },
        );
    }

    /// Returns the record containing the max key in the tree starting at node.
    pub fn get_max_cell(self: *Btree, node: Node) !Record {
        if (self.empty) {
            return .{ .cell = 0, .page = 0 };
        }

        switch (node) {
            .Leaf => {
                const leaf = node.Leaf;
                return .{ .page = leaf.base.page_index, .cell = leaf.get_num_cells() - 1 };
            },
            .Internal => {
                const internal = node.Internal;
                const right_child = internal.get_right_child_ptr();
                std.debug.assert(right_child != BaseNode.InvalidPageNum);
                const next_node = try self.get_node(right_child);
                return self.get_max_cell(next_node);
            },
        }
    }

    /// Returns the max value from the entire tree starting from node
    pub fn get_max_key(self: *Btree, node: Node) !u32 {
        if (self.empty) {
            return 0;
        }

        switch (node) {
            .Leaf => {
                const leaf = node.Leaf;
                const num_cells = leaf.get_num_cells();
                return leaf.get_key(num_cells - 1);
            },
            .Internal => {
                const internal = node.Internal;
                const right_child = internal.get_right_child_ptr();
                std.debug.assert(right_child != BaseNode.InvalidPageNum);
                const next_node = try self.get_node(right_child);
                return self.get_max_key(next_node);
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
    var empty = num_pages == 0;

    // If the number of pages in the database file was previously 0.
    // Then initialize the root node to be a new leaf node.
    if (empty) {
        root = Node{ .Leaf = base.to_leaf() };
        root.Leaf.set_next_node(BaseNode.InvalidPageNum);
        root.Leaf.set_num_cells(0);
        root.Leaf.base.set_root(true);
        root.Leaf.base.set_parent(BaseNode.InvalidPageNum);
    } else {
        const node = switch (base.get_node_type()) {
            NodeType.Leaf => Node{ .Leaf = base.to_leaf() },
            NodeType.Internal => Node{ .Internal = base.to_internal() },
        };
        root = node;
        empty = switch (root) {
            .Internal => root.Internal.get_num_cells() == 0,
            .Leaf => root.Leaf.get_num_cells() == 0,
        };
    }

    return Btree{
        .pager = p,
        .root = root,
        .empty = empty,
    };
}
