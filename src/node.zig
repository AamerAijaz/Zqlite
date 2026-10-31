const std = @import("std");
const pager = @import("pager.zig");
const Row = @import("statement.zig").Row;

pub const NodeError = error{ NumCellsExceeded, InternalNotImplemented };

pub const Node = union(NodeType) {
    Leaf: LeafNode,
    Internal: InternalNode,
};

pub const NodeType = enum(u8) { Leaf, Internal };
pub const BaseNode = struct {
    /// Common Node Header.
    pub const NodeTypeSize = @sizeOf(u8);
    pub const NodeTypeOffset = 0;
    pub const IsRootSize = @sizeOf(u8);
    pub const IsRootOffset = NodeTypeSize + NodeTypeOffset;
    pub const ParentPointerSize = @sizeOf(u32);
    pub const ParentPointerOffset = IsRootOffset + IsRootSize;
    pub const CommonHeaderSize = NodeTypeSize + IsRootSize + ParentPointerSize;

    pub const InvalidPageNum = std.math.maxInt(u32);

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

    pub fn to_internal(self: *BaseNode) InternalNode {
        return InternalNode.init(self);
    }

    pub fn peek(self: *const BaseNode, start: u32, end: u32) []u8 {
        return self.page[start..end];
    }

    /// Gets the node type for the current node.
    /// If the node-type is invalid, then we set the node-type as Leaf.
    /// The node-type maybe invalid, if the page is for the node has been newly allocated.
    pub fn get_node_type(self: *BaseNode) NodeType {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(NodeTypeOffset, NodeTypeOffset + NodeTypeSize);
        const node_type_value = std.mem.readInt(u8, destination[0..1], .little);
        if (node_type_value == @backingInt(NodeType.Leaf)) {
            return NodeType.Leaf;
        } else if (node_type_value == @backingInt(NodeType.Internal)) {
            return NodeType.Internal;
        } else {
            self.set_node_type(NodeType.Leaf);
            return NodeType.Leaf;
        }

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
        const value = std.mem.readInt(u8, buffer[0..1], .little);
        return value == 1;
    }

    pub fn set_root(self: *BaseNode, root: bool) void {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(IsRootOffset, IsRootOffset + IsRootSize);
        @memmove(destination, &std.mem.toBytes(root));
    }

    pub fn get_parent(self: *const BaseNode) u32 {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(ParentPointerOffset, ParentPointerOffset + ParentPointerSize);
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_parent(self: *BaseNode, parent: u32) void {
        std.debug.assert(self.page.len >= CommonHeaderSize);
        const destination = self.peek(ParentPointerOffset, ParentPointerOffset + ParentPointerSize);
        std.mem.writeInt(u32, destination[0..4], parent, .little);
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
    pub const RightSplitCount = MaxCells / 2;
    pub const LeftSplitCount = MaxCells - RightSplitCount;

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
        std.debug.assert(self.base.page.len >= HeaderSize + (index + 1) * CellSize);
        const start = HeaderSize + (index * CellSize);
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

    /// Adds a new cell to the node at the given index.
    /// Increments the number of cell by 1.
    pub fn add_cell(self: *LeafNode, index: u32, key: u32, buf: []const u8) void {
        const num_cells = self.get_num_cells();

        if (num_cells > 0) {
            // If the index to insert the key at is already populated.
            // We move the cells one place to the right, creating space to insert the new cell at the index.
            var cur = num_cells - 1;
            while (cur > index) : (cur -= 1) {
                @memmove(self.get_cell(cur), self.get_cell(cur - 1));
            }
        }

        const cell = self.get_cell(index);
        const destination = cell[ValueOffset .. ValueOffset + ValueSize];

        self.set_key(index, key);
        @memmove(destination, buf);

        self.set_num_cells(num_cells + 1);
    }

    pub fn remove_cell(self: *LeafNode, index: u32) !struct { u32, []u8 } {
        const num_cells = self.get_num_cells();
        if (num_cells == 0) {
            return error.ZeroCells;
        }

        const key = self.get_key(index);
        const buf = self.get_cell_value(index);

        self.set_num_cells(num_cells - 1);
        return .{ key, buf };
    }

    /// Move cells from one leaf node to another.
    pub fn move_cells(destination: LeafNode, source: LeafNode) void {
        const dest_buf = destination.base.page[BaseNode.CommonHeaderSize..];
        const source_buf = source.base.page[BaseNode.CommonHeaderSize..];
        @memmove(dest_buf, source_buf);
    }
};

pub const InternalNode = struct {
    // Internal Node Header Layout.
    pub const NumCellsSize = @sizeOf(u32);
    pub const NumCellsOffset = BaseNode.CommonHeaderSize;
    pub const RightChildSize = @sizeOf(u32);
    pub const RightChildOffset = BaseNode.CommonHeaderSize + NumCellsSize;
    pub const HeaderSize = BaseNode.CommonHeaderSize + NumCellsSize + RightChildSize;

    // Internal Node Body Layout
    pub const KeySize = @sizeOf(u32);
    pub const KeyOffset = 0;
    pub const ChildOffset = KeyOffset + KeySize;
    pub const ChildSize = @sizeOf(u32);
    pub const CellSize = ChildSize + KeySize;

    // Internal Node Constants.
    pub const MaxCells = 3;

    base: BaseNode,

    pub fn init(base: *BaseNode) InternalNode {
        base.set_node_type(NodeType.Internal);
        return InternalNode{ .base = base.* };
    }

    /// Creates a new internal node from a leaf node.
    pub fn from_leaf(leaf: LeafNode) InternalNode {
        var internal = InternalNode{
            .base = leaf.base,
        };
        internal.base.set_node_type(NodeType.Internal);
        internal.set_num_cells(0);
        internal.set_right_child_ptr(BaseNode.InvalidPageNum);

        return internal;
    }

    pub fn get_num_cells(self: *const InternalNode) u32 {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(NumCellsOffset, NumCellsOffset + NumCellsSize);
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_num_cells(self: *InternalNode, cells: u32) void {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(NumCellsOffset, NumCellsOffset + NumCellsSize);
        std.mem.writeInt(u32, destination[0..4], cells, .little);
    }

    pub fn set_right_child_ptr(self: *InternalNode, right_child_ptr: u32) void {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(RightChildOffset, RightChildOffset + RightChildSize);
        std.mem.writeInt(u32, destination[0..4], right_child_ptr, .little);
    }

    pub fn get_right_child_ptr(self: *const InternalNode) u32 {
        std.debug.assert(self.base.page.len >= HeaderSize);
        const destination = self.base.peek(RightChildOffset, RightChildOffset + RightChildSize);
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn get_cell(self: *const InternalNode, index: u32) []u8 {
        std.debug.assert(self.base.page.len >= HeaderSize + (index + 1) * CellSize);
        const start = HeaderSize + (index * CellSize);
        const end = HeaderSize + ((index + 1) * CellSize);
        return self.base.peek(start, end);
    }

    pub fn get_key(self: *const InternalNode, index: u32) u32 {
        const cell = self.get_cell(index);
        const destination = cell[KeyOffset .. KeyOffset + KeySize];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_key(self: *InternalNode, key: u32, index: u32) void {
        const cell = self.get_cell(index);
        const destination = cell[KeyOffset .. KeyOffset + KeySize];
        std.mem.writeInt(u32, destination[0..4], key, .little);
    }

    pub fn set_child_ptr(self: *InternalNode, child_ptr: u32, index: u32) void {
        const cell = self.get_cell(index);
        const destination = cell[ChildOffset .. ChildOffset + ChildSize];
        std.mem.writeInt(u32, destination[0..4], child_ptr, .little);
    }

    pub fn add_cell(self: *InternalNode, index: u32, key: u32, child_ptr: u32) void {
        const num_cells = self.get_num_cells();
        std.debug.assert(num_cells < MaxCells);
        self.set_key(key, index);
        self.set_child_ptr(child_ptr, index);
        self.set_num_cells(num_cells + 1);
    }
};
