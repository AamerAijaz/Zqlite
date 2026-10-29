const std = @import("std");
const zqlite = @import("zqlite.zig");
const statement = @import("statement.zig");

const MAX_PAGES = 100;
const PAGE_SIZE = 4096;
const ROW_SIZE = @sizeOf(Row);

// Common Node Header Layout.
const NODE_TYPE_SIZE = @sizeOf(u8);
const NODE_TYPE_OFFSET = 0;
const IS_ROOT_SIZE = @sizeOf(u8);
const IS_ROOT_OFFSET = NODE_TYPE_SIZE + NODE_TYPE_OFFSET;
const PARENT_POINTER_SIZE = @sizeOf(u32);
const PARENT_POINTER_OFFSET = IS_ROOT_OFFSET + IS_ROOT_SIZE;
const COMMON_NODE_HEADER_SIZE = NODE_TYPE_SIZE + IS_ROOT_SIZE + PARENT_POINTER_SIZE;

// Leaf Node Header Layout.
const LEAF_NODE_NUM_CELLS_SIZE = @sizeOf(u32);
const LEAF_NODE_NUM_CELLS_OFFSET = COMMON_NODE_HEADER_SIZE;
const LEAF_NODE_NEXT_LEAF_SIZE = @sizeOf(u32);
const LEAF_NODE_NEXT_LEAF_OFFSET = LEAF_NODE_NUM_CELLS_OFFSET + LEAF_NODE_NUM_CELLS_SIZE;
const LEAF_NODE_HEADER_SIZE = COMMON_NODE_HEADER_SIZE + LEAF_NODE_NUM_CELLS_SIZE + LEAF_NODE_NEXT_LEAF_SIZE;

// Leaf Node Body Layout.
const LEAF_NODE_KEY_SIZE = @sizeOf(u32);
const LEAF_NODE_KEY_OFFSET = 0;
const LEAF_NODE_VALUE_SIZE = ROW_SIZE;
const LEAF_NODE_VALUE_OFFSET = LEAF_NODE_KEY_OFFSET + LEAF_NODE_KEY_SIZE;
const LEAF_NODE_CELL_SIZE = LEAF_NODE_KEY_SIZE + LEAF_NODE_VALUE_SIZE;
const LEAF_NODE_SPACE_FOR_CELLS = PAGE_SIZE - LEAF_NODE_HEADER_SIZE;

// Leaf Node Constants.
const LEAF_NODE_MAX_CELLS = LEAF_NODE_SPACE_FOR_CELLS / LEAF_NODE_CELL_SIZE;
const LEAF_NODE_RIGHT_SPLIT_COUNT = (LEAF_NODE_MAX_CELLS + 1) / 2;
const LEAF_NODE_LEFT_SPLIT_COUNT = (LEAF_NODE_MAX_CELLS + 1) - LEAF_NODE_RIGHT_SPLIT_COUNT;

// Internal Node Header Layout.
const INTERNAL_NODE_NUM_KEYS_SIZE = @sizeOf(u32);
const INTERNAL_NODE_NUM_KEYS_OFFSET = COMMON_NODE_HEADER_SIZE;
const INTERNAL_NODE_RIGHT_CHILD_SIZE = @sizeOf(u32);
const INTERNAL_NODE_RIGHT_CHILD_OFFSET = COMMON_NODE_HEADER_SIZE + INTERNAL_NODE_NUM_KEYS_SIZE;
const INTERNAL_NODE_HEADER_SIZE = COMMON_NODE_HEADER_SIZE + INTERNAL_NODE_NUM_KEYS_SIZE + INTERNAL_NODE_RIGHT_CHILD_SIZE;

// Internal Node Body Layout
const INTERNAL_NODE_KEY_SIZE = @sizeOf(u32);
const INTERNAL_NODE_CHILD_SIZE = @sizeOf(u32);
const INTERNAL_NODE_CELL_SIZE = INTERNAL_NODE_CHILD_SIZE + INTERNAL_NODE_KEY_SIZE;

// Internal Node Constants.
const INTERNAL_NODE_MAX_CELLS = 3;

const InvalidPageNum = std.math.maxInt(u32);

const MetaCommandResult = enum { META_COMMAND_EXIT, META_COMMAND_UNRECOGNIZED_COMMAND, META_COMMAND_SUCCESS };
const PrepareResult = enum { PREPARE_SUCCESS, PREPARE_UNRECOGNIZED_STATEMENT, PREPARE_INVALID_INSERT };
const StatementType = enum { STATEMENT_INSERT, STATEMENT_SELECT };
const ExecuteResult = enum { EXECUTE_SUCCESS };
const NodeType = enum(u8) { Leaf, Internal };

pub const PrepareError = statement.PrepareError;
pub const NodeError = error{
    InvalidNodeType,
    InvalidPageNum,
};

pub const ExecuteError = error{
    TableFull,
    DuplicateKey,
};

pub const PagerError = error{
    MaxPageExceeded,
    InvalidDatabaseFileLength,
};

const CursorError = error{
    UnimplementedNodeSplitting,
};

pub const Row = statement.Row;
pub const Statement = statement.Statement;

pub const Node = struct {
    buffer: []u8,

    pub fn init(buffer: []u8) Node {
        return Node{ .buffer = buffer };
    }

    /// Initializes a node as a leaf_node.
    pub fn initialize_leaf_node(self: *Node) !void {
        self.set_node_type(NodeType.Leaf);
        self.set_node_root(false);
        try self.set_next_leaf_node(0);
        self.set_num_cells(0);
    }

    pub fn initialize_internal_node(self: *Node) !void {
        self.set_node_type(NodeType.Internal);
        self.set_node_root(false);
        try self.set_right_child(InvalidPageNum);
        try self.set_num_keys(0);
    }

    pub fn get_parent(self: *const Node) u32 {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[PARENT_POINTER_OFFSET .. PARENT_POINTER_OFFSET + PARENT_POINTER_SIZE];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_parent(self: *const Node, parent_page: u32) void {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[PARENT_POINTER_OFFSET .. PARENT_POINTER_OFFSET + PARENT_POINTER_SIZE];
        @memmove(destination, &std.mem.toBytes(parent_page));
    }

    pub fn get_next_leaf_node(self: *const Node) !u32 {
        if (self.get_node_type() != NodeType.Leaf) {
            std.debug.print("get_next_leaf_node requires leaf_node\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[LEAF_NODE_NEXT_LEAF_OFFSET .. LEAF_NODE_NEXT_LEAF_OFFSET + LEAF_NODE_NEXT_LEAF_SIZE];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_next_leaf_node(self: *const Node, next_node_page: u32) !void {
        if (self.get_node_type() != NodeType.Leaf) {
            std.debug.print("set_next_leaf_node requires leaf_node\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[LEAF_NODE_NEXT_LEAF_OFFSET .. LEAF_NODE_NEXT_LEAF_OFFSET + LEAF_NODE_NEXT_LEAF_SIZE];
        @memmove(destination, &std.mem.toBytes(next_node_page));
    }

    pub fn get_node_type(self: *const Node) NodeType {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        return @bitCast(self.buffer[NODE_TYPE_OFFSET .. NODE_TYPE_OFFSET + NODE_TYPE_SIZE].*);
    }

    pub fn set_node_type(self: *Node, node_type: NodeType) void {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[NODE_TYPE_OFFSET .. NODE_TYPE_OFFSET + NODE_TYPE_SIZE];
        const source: u8 = @backingInt(node_type);
        @memcpy(destination, (&source)[0..1]);
    }

    pub fn is_root(self: *const Node) bool {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        return !std.mem.allEqual(u8, self.buffer[IS_ROOT_OFFSET .. IS_ROOT_OFFSET + IS_ROOT_SIZE], 0);
    }

    pub fn set_node_root(self: *Node, root: bool) void {
        std.debug.assert(self.buffer.len >= COMMON_NODE_HEADER_SIZE);
        const destination = self.buffer[IS_ROOT_OFFSET .. IS_ROOT_OFFSET + IS_ROOT_SIZE];
        @memcpy(destination, &std.mem.toBytes(root));
    }

    pub fn get_num_keys(self: *const Node) !u32 {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: get_num_keys requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= INTERNAL_NODE_HEADER_SIZE);
        const destination = self.buffer[INTERNAL_NODE_NUM_KEYS_OFFSET .. INTERNAL_NODE_NUM_KEYS_OFFSET + INTERNAL_NODE_NUM_KEYS_SIZE];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_num_keys(self: *Node, num_keys: u32) !void {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: set_num_keys requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= INTERNAL_NODE_HEADER_SIZE);
        const destination = self.buffer[INTERNAL_NODE_NUM_KEYS_OFFSET .. INTERNAL_NODE_NUM_KEYS_OFFSET + INTERNAL_NODE_NUM_KEYS_SIZE];
        @memcpy(destination, &std.mem.toBytes(num_keys));
    }

    pub fn get_right_child(self: *const Node) !u32 {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: get_right_child requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= INTERNAL_NODE_HEADER_SIZE);
        const destination = self.buffer[INTERNAL_NODE_RIGHT_CHILD_OFFSET .. INTERNAL_NODE_RIGHT_CHILD_OFFSET + INTERNAL_NODE_RIGHT_CHILD_SIZE];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_right_child(self: *Node, right_child: u32) !void {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: set_right_child requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        std.debug.assert(self.buffer.len >= INTERNAL_NODE_HEADER_SIZE);
        const destination = self.buffer[INTERNAL_NODE_RIGHT_CHILD_OFFSET .. INTERNAL_NODE_RIGHT_CHILD_OFFSET + INTERNAL_NODE_RIGHT_CHILD_SIZE];
        @memcpy(destination, &std.mem.toBytes(right_child));
    }

    pub fn get_num_cells(self: *const Node) u32 {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE);
        const destination = self.buffer[LEAF_NODE_NUM_CELLS_OFFSET .. LEAF_NODE_NUM_CELLS_OFFSET + LEAF_NODE_NUM_CELLS_SIZE];
        return std.mem.readInt(u32, destination[0..4], .little);
    }

    pub fn set_num_cells(self: *Node, num_cells: u32) void {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE);
        const destination = self.buffer[LEAF_NODE_NUM_CELLS_OFFSET .. LEAF_NODE_NUM_CELLS_OFFSET + LEAF_NODE_NUM_CELLS_SIZE];
        @memcpy(destination, &std.mem.toBytes(num_cells));
    }

    pub fn get_cell(self: *const Node, cell_num: u32) []u8 {
        const is_internal = self.get_node_type() == NodeType.Internal;
        const header_size: u32 = if (is_internal) INTERNAL_NODE_HEADER_SIZE else LEAF_NODE_HEADER_SIZE;
        const cell_size: u32 = if (is_internal) INTERNAL_NODE_CELL_SIZE else LEAF_NODE_CELL_SIZE;

        std.debug.assert(self.buffer.len >= header_size + (cell_num + 1) * cell_size);

        const start_position = header_size + cell_num * cell_size;
        const end_position = header_size + (cell_num + 1) * cell_size;
        return self.buffer[start_position..end_position];
    }

    pub fn get_cell_key(self: *const Node, cell_num: u32) []u8 {
        const is_internal = self.get_node_type() == NodeType.Internal;
        const key_size: u32 = if (is_internal) INTERNAL_NODE_KEY_SIZE else LEAF_NODE_KEY_SIZE;
        const start_position: u32 = if (is_internal) INTERNAL_NODE_CHILD_SIZE else 0;
        const end_position = start_position + key_size;

        const cell = self.get_cell(cell_num);
        return cell[start_position..end_position];
    }

    pub fn get_cell_key_value(self: *const Node, cell_num: u32) u32 {
        const cell_key = self.get_cell_key(cell_num);
        return std.mem.readInt(u32, cell_key[0..4], .little);
    }

    pub fn set_cell_key(self: *Node, cell_num: u32, key: u32) void {
        const cell_key = self.get_cell_key(cell_num);
        @memcpy(cell_key, &std.mem.toBytes(key));
    }

    pub fn get_cell_value(self: *const Node, cell_num: u32) ![]u8 {
        if (self.get_node_type() != NodeType.Leaf) {
            std.debug.print("Invalid Node Type: get_cell_value requires leaf node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        const cell = self.get_cell(cell_num);
        return cell[LEAF_NODE_VALUE_OFFSET .. LEAF_NODE_VALUE_OFFSET + LEAF_NODE_VALUE_SIZE];
    }

    pub fn get_child_pointer(self: *const Node, cell_num: u32) !u32 {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: get_child_pointer requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        const num_keys = try self.get_num_keys();
        if (cell_num == num_keys) {
            const right_child_page = try self.get_right_child();
            if (right_child_page == InvalidPageNum) {
                std.debug.print("Trying to access Invalid page num: \n", .{});
                return NodeError.InvalidPageNum;
            }
            return right_child_page;
        }

        const cell = self.get_cell(cell_num);
        const buffer = cell[0..INTERNAL_NODE_CHILD_SIZE];
        const child_page = std.mem.readInt(u32, buffer[0..4], .little);
        if (child_page == InvalidPageNum) {
            std.debug.print("Trying to access Invalid page num: \n", .{});
            return NodeError.InvalidPageNum;
        }
        return child_page;
    }

    pub fn set_child_pointer(self: *Node, cell_num: u32, child_page_num: u32) !void {
        if (self.get_node_type() != NodeType.Internal) {
            std.debug.print("Invalid Node Type: set_child_pointer requires internal node:\n", .{});
            return NodeError.InvalidNodeType;
        }
        const cell = self.get_cell(cell_num);
        const buffer = cell[0..INTERNAL_NODE_CHILD_SIZE];
        @memcpy(buffer, &std.mem.toBytes(child_page_num));
    }

    pub fn get_max_key(self: *const Node) ![]u8 {
        return switch (self.get_node_type()) {
            NodeType.Leaf => self.get_cell_key(self.get_num_cells() - 1),
            NodeType.Internal => self.get_cell_key(try self.get_num_keys() - 1),
        };
    }

    pub fn get_max_key_value(self: *const Node, pager: *Pager, io: std.Io, allocator: std.mem.Allocator) !u32 {
        if (self.get_node_type() == NodeType.Leaf) {
            const max_key = try self.get_max_key();
            return std.mem.readInt(u32, max_key[0..4], .little);
        }
        const right_node = try pager.get_node(io, allocator, try self.get_right_child());
        return try right_node.get_max_key_value(pager, io, allocator);
    }
};

pub const Page = [PAGE_SIZE]u8;
pub const Pager = struct {
    database_file: std.Io.File,
    database_file_length: u64,
    num_pages: u32,
    pages: [MAX_PAGES]?*Page = @splat(null), // An in-memory cache of the pages fetched or inserted.

    pub fn init(io: std.Io, path: []const u8) !Pager {
        const database_file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{
            .mode = .read_write,
        });

        const database_file_length = try database_file.length(io);
        const num_pages = database_file_length / PAGE_SIZE;

        if (database_file_length % PAGE_SIZE != 0) {
            return PagerError.InvalidDatabaseFileLength;
        }

        return Pager{
            .database_file = database_file,
            .database_file_length = database_file_length,
            .pages = @splat(null),
            .num_pages = @intCast(num_pages),
        };
    }

    pub fn deinit(self: *Pager, io: std.Io, allocator: std.mem.Allocator) !void {
        for (0..self.num_pages + 1) |page_num| {
            if (self.pages[page_num]) |page| {
                const offset = page_num * PAGE_SIZE;
                _ = try self.database_file.writePositional(io, &.{page.*[0..]}, offset);

                allocator.destroy(page);
            }
        }

        self.database_file.close(io);
    }

    pub fn get_page(self: *Pager, io: std.Io, allocator: std.mem.Allocator, page_num: u32) !*Page {
        if (page_num > MAX_PAGES) {
            std.debug.print("Cannot fetch beyond max fetch, returning!\n", .{});
            return PagerError.MaxPageExceeded;
        }

        const page = self.pages[page_num] orelse {
            const p = try allocator.create(Page);

            const offset = page_num * PAGE_SIZE;
            _ = try self.database_file.readPositional(io, &.{p}, offset);

            if (page_num >= self.num_pages) {
                self.num_pages += 1;
            }

            self.pages[page_num] = p;
            return p;
        };

        return page;
    }

    pub fn get_node(self: *Pager, io: std.Io, allocator: std.mem.Allocator, page_num: u32) !Node {
        const page = try self.get_page(io, allocator, page_num);
        return Node.init(page);
    }

    pub fn get_unused_page_num(self: *Pager) u32 {
        return self.num_pages;
    }
};

pub const Table = struct {
    pager: Pager,
    root_page_num: u32 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Table {
        var pager = try Pager.init(io, path);

        // Initialize the root_node if it is a new table.
        if (pager.num_pages == 0) {
            var root_node = try pager.get_node(io, allocator, 0);
            try root_node.initialize_leaf_node();
            root_node.set_node_root(true);
        }

        return Table{
            .pager = pager,
            .root_page_num = 0,
        };
    }

    pub fn deinit(self: *Table, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.pager.deinit(io, allocator);
    }

    pub fn execute_statement(self: *Table, io: std.Io, allocator: std.mem.Allocator, stmt: *Statement) !ExecuteResult {
        switch (stmt.statement_type) {
            StatementType.STATEMENT_INSERT => {
                const row = &stmt.row_to_insert;
                var cursor = try Cursor.find(self, io, allocator, row.id);
                const node = try cursor.table.pager.get_node(io, allocator, cursor.page_num);
                const num_cells = node.get_num_cells();

                if (cursor.cell_num < num_cells) {
                    const cell_key = node.get_cell_key_value(cursor.cell_num);
                    if (cell_key == row.id) {
                        return ExecuteError.DuplicateKey;
                    }
                }

                try cursor.insert_row(io, allocator, stmt.row_to_insert.id, &stmt.row_to_insert);
            },
            StatementType.STATEMENT_SELECT => {
                var cursor = try Cursor.start(self, io, allocator);
                while (cursor.end_of_table == false) {
                    const row = try deserialize_row(try cursor.value(io, allocator));
                    std.debug.print("Row - {d}, {s}, {s}\n", .{ row.id, row.username, row.email });
                    try cursor.advance(io, allocator);
                }
            },
        }

        std.debug.print("Executed", .{});
        return ExecuteResult.EXECUTE_SUCCESS;
    }

    pub fn create_new_root(self: *Table, io: std.Io, allocator: std.mem.Allocator, right_child_page_num: u32) !void {
        const root = try self.pager.get_page(io, allocator, self.root_page_num);
        var root_node = Node.init(root);

        const left_child_page_num = self.pager.get_unused_page_num();
        const left_child = try self.pager.get_page(
            io,
            allocator,
            left_child_page_num,
        );
        var left_child_node = Node.init(left_child);
        var right_child_node = try self.pager.get_node(io, allocator, right_child_page_num);

        if (root_node.get_node_type() == NodeType.Internal) {
            try left_child_node.initialize_internal_node();
            try right_child_node.initialize_internal_node();
        }

        @memmove(left_child, root);
        left_child_node.set_node_root(false);
        if (left_child_node.get_node_type() == NodeType.Leaf) {
            try left_child_node.set_next_leaf_node(right_child_page_num);
        }

        if (left_child_node.get_node_type() == NodeType.Internal) {
            var child: Node = undefined;
            for (0..try left_child_node.get_num_keys()) |index| {
                child = try self.pager.get_node(io, allocator, @intCast(index));
                child.set_parent(left_child_page_num);
            }
            child = try self.pager.get_node(io, allocator, try left_child_node.get_right_child());
            child.set_parent(left_child_page_num);
        }

        try root_node.initialize_internal_node();
        root_node.set_node_root(true);
        try root_node.set_num_keys(1);
        try root_node.set_child_pointer(0, left_child_page_num);
        root_node.set_cell_key(0, try left_child_node.get_max_key_value(&self.pager, io, allocator));
        try root_node.set_right_child(right_child_page_num);

        left_child_node.set_parent(self.root_page_num);
        right_child_node.set_parent(self.root_page_num);
    }
};

pub const Cursor = struct {
    table: *Table,
    page_num: u32,
    cell_num: u32,
    end_of_table: bool,

    pub fn root(table: *Table, io: std.Io, allocator: std.mem.Allocator) !Cursor {
        const root_node = try table.pager.get_node(io, allocator, table.root_page_num);

        return Cursor{
            .table = table,
            .page_num = table.root_page_num,
            .cell_num = 0,
            .end_of_table = root_node.get_num_cells() == 0,
        };
    }

    /// Returns a cursor at the start of the table.
    pub fn start(table: *Table, io: std.Io, allocator: std.mem.Allocator) !Cursor {
        var cursor = try Cursor.find(table, io, allocator, 0);
        const node = try cursor.table.pager.get_node(io, allocator, cursor.page_num);
        cursor.end_of_table = (node.get_num_cells() == 0);
        return cursor;
    }

    /// Returns a cursor at the end of the table.
    pub fn end(table: *Table, io: std.Io, allocator: std.mem.Allocator) !Cursor {
        const node = try table.pager.get_node(io, allocator, table.root_page_num);

        return Cursor{
            .table = table,
            .page_num = table.root_page_num,
            .cell_num = node.get_num_cells(),
            .end_of_table = true,
        };
    }

    /// Finds the cell and page closest to the given key.
    /// The page value pointed to by the cursor will be a leaf node.
    pub fn find(table: *Table, io: std.Io, allocator: std.mem.Allocator, key: u32) !Cursor {
        var cursor = try Cursor.root(table, io, allocator);
        var root_node = try cursor.table.pager.get_node(io, allocator, table.root_page_num);

        if (root_node.get_node_type() == NodeType.Leaf) {
            try cursor.find_in_leaf_node(root_node, key);
        } else {
            try cursor.find_in_internal_node(io, allocator, root_node, key);
        }

        return cursor;
    }

    pub fn find_in_leaf_node(self: *Cursor, node: Node, key: u32) !void {
        var min_index: u32 = 0;
        var one_past_max_index = node.get_num_cells();

        while (min_index != one_past_max_index) {
            const index = (min_index + one_past_max_index) / 2;
            const cell_key = node.get_cell_key_value(index);

            if (cell_key == key) {
                self.cell_num = index;
                return;
            } else if (cell_key > key) {
                one_past_max_index = index;
            } else {
                min_index = index + 1;
            }
        }

        self.cell_num = min_index;
    }

    /// Returns cell number or index.
    pub fn find_internal_node_child(_: *Cursor, node: Node, key: u32) !u32 {
        const num_keys = try node.get_num_keys();
        var min_index: u32 = 0;
        var max_index: u32 = num_keys;
        while (min_index != max_index) {
            const index = (min_index + max_index) / 2;
            const key_at_index = node.get_cell_key_value(index);
            if (key_at_index >= key) {
                max_index = index;
            } else {
                min_index = index + 1;
            }
        }

        return min_index;
    }

    pub fn find_in_internal_node(self: *Cursor, io: std.Io, allocator: std.mem.Allocator, node: Node, key: u32) !void {
        const index = try self.find_internal_node_child(node, key);
        const child_page = try node.get_child_pointer(index);
        const child_node = try self.table.pager.get_node(io, allocator, child_page);

        self.page_num = child_page;
        switch (child_node.get_node_type()) {
            NodeType.Internal => try self.find_in_internal_node(io, allocator, child_node, key),
            NodeType.Leaf => try self.find_in_leaf_node(child_node, key),
        }
    }

    /// Returns the current cell in bytes present at the current cursor position.
    pub fn value(self: *Cursor, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        const node = try self.table.pager.get_node(io, allocator, self.page_num);
        return try node.get_cell_value(self.cell_num);
    }

    /// advances the cursor to the next cell in the page.
    pub fn advance(self: *Cursor, io: std.Io, allocator: std.mem.Allocator) !void {
        const node = try self.table.pager.get_node(io, allocator, self.page_num);
        const next_node_page = try node.get_next_leaf_node();

        if (self.cell_num + 1 >= node.get_num_cells() and next_node_page != 0) {
            self.page_num = next_node_page;
            self.cell_num = 0;
        } else {
            self.cell_num += 1;
            self.end_of_table = self.cell_num >= node.get_num_cells();
        }
    }

    pub fn insert_row(self: *Cursor, io: std.Io, allocator: std.mem.Allocator, key: u32, row: *const Row) !void {
        var node = try self.table.pager.get_node(io, allocator, self.page_num);
        const num_cells = node.get_num_cells();

        if (num_cells >= LEAF_NODE_MAX_CELLS) {
            // If the number of cells exceed the max number of cells in a leaf-node.
            // We split the cells into two new nodes (left and right).
            var source_node = node;
            const parent_page_num = source_node.get_parent();

            // We first create a new leaf-node. This new leaf node will lead to a new page being allocated.
            const next_page = self.table.pager.get_unused_page_num();
            var new_node = try self.table.pager.get_node(io, allocator, next_page);
            try new_node.initialize_leaf_node();
            new_node.set_parent(parent_page_num);

            const old_max = try source_node.get_max_key_value(&self.table.pager, io, allocator);
            std.debug.print("Max key value - old {d}\n", .{old_max});

            // Split the cells between the new node and the original node.
            var index: u32 = LEAF_NODE_MAX_CELLS;
            while (index >= 0) {
                var destination_node = if (index >= LEAF_NODE_LEFT_SPLIT_COUNT) new_node else source_node;
                const destination_cell_num: u32 = @intCast(index % LEAF_NODE_LEFT_SPLIT_COUNT);

                if (index == self.cell_num) {
                    serialize_row(row, try destination_node.get_cell_value(destination_cell_num));
                    destination_node.set_cell_key(destination_cell_num, key);
                } else if (index > self.cell_num) {
                    const source_cell_num: u32 = @intCast(index - 1);
                    @memmove(destination_node.get_cell(destination_cell_num), source_node.get_cell(source_cell_num));
                } else {
                    const source_cell_num: u32 = @intCast(index);
                    @memmove(destination_node.get_cell(destination_cell_num), source_node.get_cell(source_cell_num));
                }

                if (index == 0) break;
                index -= 1;
            }

            try source_node.set_next_leaf_node(next_page);
            source_node.set_num_cells(LEAF_NODE_LEFT_SPLIT_COUNT);
            new_node.set_num_cells(LEAF_NODE_RIGHT_SPLIT_COUNT);

            const new_max = try source_node.get_max_key_value(&self.table.pager, io, allocator);
            std.debug.print("Max key value - new {d}\n", .{new_max});

            if (source_node.is_root()) {
                try self.table.create_new_root(io, allocator, next_page);
                return;
            } else {
                var parent_node = try self.table.pager.get_node(io, allocator, parent_page_num);
                try self.update_key(&parent_node, old_max, new_max);

                try self.insert_internal_node(io, allocator, parent_page_num, next_page);
                return;
            }
        }

        if (self.cell_num < num_cells) {
            var cell_num = num_cells;
            while (cell_num > self.cell_num) : (cell_num -= 1) {
                @memmove(node.get_cell(cell_num), node.get_cell(cell_num - 1));
            }
        }

        node.set_num_cells(num_cells + 1);
        node.set_cell_key(self.cell_num, key);
        serialize_row(row, try node.get_cell_value(self.cell_num));
    }

    pub fn insert_internal_node(self: *Cursor, io: std.Io, allocator: std.mem.Allocator, parent_page_num: u32, child_page_num: u32) !void {
        var parent_node = try self.table.pager.get_node(io, allocator, parent_page_num);
        var child_node = try self.table.pager.get_node(io, allocator, child_page_num);

        const child_max_key = try child_node.get_max_key_value(&self.table.pager, io, allocator);
        const index = try self.find_internal_node_child(parent_node, child_max_key);

        const original_num_keys = try parent_node.get_num_keys();
        if (original_num_keys >= INTERNAL_NODE_MAX_CELLS) {
            var old_page_num = parent_page_num;

            var old_node = try self.table.pager.get_node(io, allocator, old_page_num);
            const old_max = try old_node.get_max_key_value(&self.table.pager, io, allocator);

            var child = try self.table.pager.get_node(io, allocator, child_page_num);
            const child_max = try child.get_max_key_value(&self.table.pager, io, allocator);

            const new_page_num = self.table.pager.get_unused_page_num();
            var parent: Node = undefined;
            var new_node: Node = undefined;
            const splitting_root = old_node.is_root();
            if (splitting_root) {
                try self.table.create_new_root(io, allocator, new_page_num);
                parent = try self.table.pager.get_node(io, allocator, self.table.root_page_num);
                old_page_num = try parent.get_child_pointer(0);
                old_node = try self.table.pager.get_node(io, allocator, old_page_num);
            } else {
                parent = try self.table.pager.get_node(io, allocator, old_node.get_parent());
                new_node = try self.table.pager.get_node(io, allocator, new_page_num);
            }

            var old_num_keys = try old_node.get_num_keys();
            var cur_page_num = try old_node.get_right_child();
            var cur = try self.table.pager.get_node(io, allocator, cur_page_num);

            try self.insert_internal_node(io, allocator, new_page_num, cur_page_num);
            cur.set_parent(new_page_num);
            try old_node.set_right_child(@intCast(InvalidPageNum));

            var i: u32 = INTERNAL_NODE_MAX_CELLS - 1;
            const split_point: u32 = INTERNAL_NODE_MAX_CELLS / 2;
            while (i > split_point) : (i -= 1) {
                cur_page_num = try old_node.get_child_pointer(i);
                cur = try self.table.pager.get_node(io, allocator, cur_page_num);
                try self.insert_internal_node(io, allocator, new_page_num, cur_page_num);
                cur.set_parent(new_page_num);
                old_num_keys -= 1;
            }

            try old_node.set_right_child(try old_node.get_child_pointer(old_num_keys - 1));
            old_num_keys -= 1;

            const max_after_split = try old_node.get_max_key_value(&self.table.pager, io, allocator);
            const destination_page_num = if (child_max < max_after_split) old_page_num else new_page_num;
            try self.insert_internal_node(io, allocator, destination_page_num, child_page_num);
            child.set_parent(destination_page_num);

            try self.update_key(&parent, old_max, try old_node.get_max_key_value(&self.table.pager, io, allocator));

            if (!splitting_root) {
                try self.insert_internal_node(io, allocator, old_node.get_parent(), new_page_num);
                new_node.set_parent(old_node.get_parent());
            }

            return;
        }

        const right_child_page_num = try parent_node.get_right_child();
        if (right_child_page_num == InvalidPageNum) {
            try parent_node.set_right_child(child_page_num);
            return;
        }

        try parent_node.set_num_keys(original_num_keys + 1);
        const right_child_node = try self.table.pager.get_node(io, allocator, right_child_page_num);
        const right_child_max_key = try right_child_node.get_max_key_value(&self.table.pager, io, allocator);

        if (child_max_key > right_child_max_key) {
            try parent_node.set_right_child(child_page_num);
            try parent_node.set_child_pointer(original_num_keys, right_child_page_num);
            parent_node.set_cell_key(original_num_keys, right_child_max_key);
        } else {
            var key: u32 = original_num_keys;
            while (key > index) {
                const destination = parent_node.get_cell(key);
                const source = parent_node.get_cell(key - 1);
                @memmove(destination, source);

                if (key == index) break;
                key -= 1;
            }

            try parent_node.set_child_pointer(index, child_page_num);
            parent_node.set_cell_key(index, child_max_key);
        }
    }

    pub fn update_key(self: *Cursor, node: *Node, old_max: u32, new_max: u32) !void {
        if (node.get_node_type() != NodeType.Internal) {
            std.debug.print("update_key requires internal node\n", .{});
            return NodeError.InvalidNodeType;
        }

        const cell_num = try self.find_internal_node_child(node.*, old_max);
        node.set_cell_key(cell_num, new_max);
        try node.set_child_pointer(cell_num, self.page_num);
    }
};

pub fn serialize_row(row: *const Row, destination: []u8) void {
    @memcpy(destination, std.mem.asBytes(row));
}

pub fn deserialize_row(source: []u8) !Row {
    const row = std.mem.bytesToValue(Row, source);
    return row;
}

pub fn do_meta_command(line: []const u8, io: std.Io, allocator: std.mem.Allocator, table: *Table) !MetaCommandResult {
    if (std.mem.eql(u8, line, ".exit")) {
        return MetaCommandResult.META_COMMAND_EXIT;
    } else if (std.mem.eql(u8, line, ".btree")) {
        try print_tree(io, allocator, table);
        return MetaCommandResult.META_COMMAND_SUCCESS;
    } else {
        return MetaCommandResult.META_COMMAND_UNRECOGNIZED_COMMAND;
    }
}

pub fn open_database(io: std.Io, path: []const u8) !Table {
    return try .init(io, path);
}

pub fn print_tree(io: std.Io, allocator: std.mem.Allocator, table: *Table) !void {
    const root = try table.pager.get_node(io, allocator, table.root_page_num);
    try print_tree_indent(io, allocator, table, &root, 0);
}

pub fn print_tree_indent(io: std.Io, allocator: std.mem.Allocator, table: *Table, node: *const Node, indent: u32) !void {
    for (0..indent + 1) |_| {
        std.debug.print(" ", .{});
    }

    switch (node.get_node_type()) {
        NodeType.Internal => {
            const num_keys = try node.get_num_keys();
            std.debug.print("- internal (size {d})\n", .{num_keys});

            for (0..num_keys) |key| {
                const key_x = node.get_cell_key_value(@intCast(key));
                std.debug.print("key - {d}\n", .{key_x});
                const child_page = try node.get_child_pointer(@intCast(key));
                const child_node = try table.pager.get_node(io, allocator, child_page);
                try print_tree_indent(io, allocator, table, &child_node, indent + 1);
            }

            const right_child_page = try node.get_right_child();
            const right_child_node = try table.pager.get_node(io, allocator, right_child_page);
            try print_tree_indent(io, allocator, table, &right_child_node, indent + 1);
            std.debug.print("\n", .{});
        },
        NodeType.Leaf => {
            const num_cells = node.get_num_cells();
            std.debug.print("- leaf (size {d})\n", .{num_cells});

            for (0..num_cells) |cell_num| {
                const cell = try node.get_cell_value(@intCast(cell_num));
                const key = node.get_cell_key_value(@intCast(cell_num));
                const row = try deserialize_row(cell);
                std.debug.print(" - {d} {s}, key - {d}\n", .{ row.id, row.username, key });
            }
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();

    _ = args.next();
    const database_path = args.next();
    if (database_path == null) {
        std.debug.print("Valid database path required.\n", .{});
        return;
    }

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var connection = try zqlite.connect(io, allocator, database_path.?);
    defer connection.close();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (true) {
        try stdout_writer.print("zqlite> ", .{});
        try stdout_writer.flush();

        const line = try stdin_reader.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");

        if (trimmed.len == 0) {
            continue;
        }

        if (trimmed[0] == '.') {
            const result = connection.execute_meta_command(trimmed);
            switch (result) {
                zqlite.MetaCommandResult.Success => {},
                zqlite.MetaCommandResult.Exit => {
                    return;
                },
                zqlite.MetaCommandResult.UnrecognizedCommand => {
                    try stdout_writer.print("Error: Unrecognized meta command: {s}", .{line});
                    try stdout_writer.flush();
                },
            }
        } else {
            const stmt: Statement = statement.prepare_statement(trimmed) catch |err| switch (err) {
                PrepareError.InvalidInsert => {
                    try stdout_writer.print("Error: Could not parse statement", .{});
                    try stdout_writer.flush();
                    continue;
                },
                PrepareError.UnrecognizedStatement => {
                    try stdout_writer.print("Error: Unrecognized keyword at the start {s}", .{trimmed});
                    try stdout_writer.flush();
                    continue;
                },
            };

            try connection.execute_statement(stmt, stdout_writer);
            try stdout_writer.print("Executed.", .{});
            try stdout_writer.flush();
        }

        try stdout_writer.print("\n", .{});
        try stdout_writer.flush();
    }
}
