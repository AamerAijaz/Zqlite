const std = @import("std");
const pager = @import("pager.zig");
const Row = @import("statement.zig").Row;

pub const NodeError = error{ NumCellsExceeded, InternalNotImplemented };

pub const Node = union(NodeType) {
    Leaf: LeafNode,
    Internal: void,
};

pub const NodeType = enum(u8) { Leaf, Internal };
pub const BaseNode = struct {
    /// Common Node Header.
    const NodeTypeSize = @sizeOf(u8);
    const NodeTypeOffset = 0;
    const IsRootSize = @sizeOf(u8);
    const IsRootOffset = NodeTypeSize + NodeTypeOffset;
    const ParentPointerSize = @sizeOf(u32);
    const ParentPointerOffset = IsRootOffset + IsRootSize;
    const CommonHeaderSize = NodeTypeSize + IsRootSize + ParentPointerSize;

    page_index: u32,
    page: []u8,

    pub fn init(page: *pager.Page, index: u32) BaseNode {
        return BaseNode{
            .page_index = index,
            .page = page,
        };
    }

    pub fn to_leaf(self: *BaseNode) LeafNode {
        return LeafNode.init(self);
    }

    pub fn peek(self: *const BaseNode, start: u32, end: u32) []u8 {
        return self.page[start..end];
    }

    pub fn get_node_type(self: *const BaseNode) NodeType {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(NodeTypeOffset, NodeTypeOffset + NodeTypeSize);
        const node_type_value = std.mem.readInt(u8, destination[0..1], .little);
        return @fromBackingInt(node_type_value);
    }

    pub fn set_node_type(self: *BaseNode, node_type: NodeType) void {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(NodeTypeOffset, NodeTypeOffset + NodeTypeSize);
        @memmove(destination, &std.mem.toBytes(node_type));
    }

    pub fn is_root(self: *const BaseNode) bool {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const buffer = self.peek(IsRootOffset, IsRootOffset + IsRootSize);
        return !std.mem.allEqual(u8, buffer, 0);
    }

    pub fn set_root(self: *BaseNode, root: bool) void {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(IsRootOffset, IsRootOffset + IsRootSize);
        @memmove(destination, &std.mem.toBytes(root));
    }
};

pub const LeafNode = struct {
    /// Leaf Node Header Layout.
    pub const NumCellsSize = @sizeOf(u32);
    pub const NumCellsOffset = BaseNode.CommonHeaderSize;
    pub const NextLeafSize = @sizeOf(u32);
    pub const NextLeafOffset = NumCellsOffset + NumCellsSize;
    pub const HeaderSize = BaseNode.CommonHeaderSize + NumCellsSize + NextLeafSize;

    /// Leaf Node Body Layout
    pub const KeySize = @sizeOf(u32);
    pub const KeyOffset = 0;
    pub const ValueSize = @sizeOf(Row);
    pub const ValueOffset = KeyOffset + KeySize;
    pub const CellSize = KeySize + ValueSize;

    /// Leaf Node Constants.
    pub const CellSpace = pager.page_size - HeaderSize;
    pub const MaxCells = CellSpace / CellSize;
    pub const RightSplitCount = (MaxCells + 1) / 2;
    pub const LeafSplitCount = MaxCells + 1 - RightSplitCount;

    base: BaseNode,

    pub fn init(node: *BaseNode) LeafNode {
        node.set_node_type(NodeType.Leaf);
        return LeafNode{ .base = node.* };
    }

    pub fn get_next_node(self: *const LeafNode) u32 {
        std.debug.assert(self.base.page.len >= HeaderSize);

        const destination = self.base.peek(NextLeafOffset, NextLeafOffset + NextLeafSize);
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    /// TODO: convert memmove to std.mem.writeInt with litte endian
    pub fn set_next_node(self: *LeafNode, index: u32) void {
        std.debug.assert(self.base.page.len >= HeaderSize);

        const destination = self.base.peek(NextLeafOffset, NextLeafOffset + NextLeafSize);
        @memmove(destination, &std.mem.toBytes(index));
    }

    pub fn get_num_cells(self: *const LeafNode) u32 {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(NumCellsOffset, NumCellsOffset + NumCellsSize);
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    /// TODO: convert memmove to std.mem.writeInt with litte endian
    pub fn set_num_cells(self: *LeafNode, cells: u32) void {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(NumCellsOffset, NumCellsOffset + NumCellsSize);
        @memmove(destination, &std.mem.toBytes(cells));
    }

    pub fn get_cell(self: *const LeafNode, index: u32) []u8 {
        std.debug.assert(self.base.page.len >= HeaderSize + CellSize);
        const start = HeaderSize + index * CellSize;
        const end = HeaderSize + (index + 1) * CellSize;
        return self.base.peek(start, end);
    }

    pub fn get_key(self: *const LeafNode, index: u32) u32 {
        const cell = self.get_cell(index);
        const key_buf = cell[KeyOffset .. KeyOffset + KeySize];
        return std.mem.readInt(u32, key_buf[0..4], .little);
    }

    pub fn set_key(self: *LeafNode, index: u32, key: u32) void {
        const cell = self.get_cell(index);
        const key_buf = cell[KeyOffset .. KeyOffset + KeySize];
        std.mem.writeInt(u32, key_buf[0..4], key, .little);
    }

    pub fn get_cell_value(self: *const LeafNode, index: u32) []u8 {
        const buf = self.get_cell(index);
        return buf[ValueOffset .. ValueOffset + ValueSize];
    }

    /// Adds a new cell to the node.
    /// Increments the number of cell by 1.
    pub fn add_cell(self: *LeafNode, key: u32, buf: []const u8) void {
        const num_cells = self.get_num_cells();
        const cell = self.get_cell(num_cells);
        const destination = cell[ValueOffset .. ValueOffset + ValueSize];

        self.set_key(num_cells, key);
        @memmove(destination, buf);

        self.set_num_cells(num_cells + 1);
    }
};
