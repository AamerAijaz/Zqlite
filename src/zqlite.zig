const std = @import("std");
const Io = std.Io;

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
const LEAF_NODE_HEADER_SIZE = COMMON_NODE_HEADER_SIZE + LEAF_NODE_NUM_CELLS_SIZE;

// Lead Node Body Layout.
const LEAF_NODE_KEY_SIZE = @sizeOf(u32);
const LEAF_NODE_KEY_OFFSET = 0;
const LEAF_NODE_VALUE_SIZE = ROW_SIZE;
const LEAF_NODE_VALUE_OFFSET = LEAF_NODE_KEY_OFFSET + LEAF_NODE_KEY_SIZE;
const LEAF_NODE_CELL_SIZE = LEAF_NODE_KEY_SIZE + LEAF_NODE_VALUE_SIZE;
const LEAF_NODE_SPACE_FOR_CELLS = PAGE_SIZE - LEAF_NODE_HEADER_SIZE;
const LEAF_NODE_MAX_CELLS = LEAF_NODE_SPACE_FOR_CELLS / LEAF_NODE_CELL_SIZE;

const MetaCommandResult = enum { META_COMMAND_EXIT, META_COMMAND_UNRECOGNIZED_COMMAND };
const PrepareResult = enum { PREPARE_SUCCESS, PREPARE_UNRECOGNIZED_STATEMENT, PREPARE_INVALID_INSERT };
const StatementType = enum { STATEMENT_INSERT, STATEMENT_SELECT };
const ExecuteResult = enum { EXECUTE_SUCCESS };
const NodeType = enum(u8) { NODE_LEAF, NODE_INTERNAL };

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

pub const Row = extern struct {
    id: u32,
    username: [32]u8,
    email: [255]u8,
};

pub const Statement = struct {
    statement_type: StatementType,
    row_to_insert: Row,

    pub fn prepare_statement(statement: *Statement, line: []const u8) PrepareResult {
        if (std.mem.startsWith(u8, line, "insert")) {
            const remaining = std.mem.cutPrefix(u8, line, "insert");

            if (remaining == null) {
                return PrepareResult.PREPARE_UNRECOGNIZED_STATEMENT;
            }

            if (remaining.?.len == 0 or remaining.?[0] != ' ') {
                return PrepareResult.PREPARE_INVALID_INSERT;
            }

            const trimmed = std.mem.trim(u8, remaining.?, " ");
            var iterator = std.mem.tokenizeScalar(u8, trimmed, ' ');

            const id = iterator.next();
            if (id == null) {
                return PrepareResult.PREPARE_INVALID_INSERT;
            }

            const username = iterator.next();
            if (username == null or username.?.len > 32) {
                return PrepareResult.PREPARE_INVALID_INSERT;
            }

            const email = iterator.next();
            if (email == null or email.?.len > 255) {
                return PrepareResult.PREPARE_INVALID_INSERT;
            }

            statement.row_to_insert = Row{ .id = 0, .email = std.mem.zeroes([255]u8), .username = std.mem.zeroes([32]u8) };
            statement.row_to_insert.id = std.fmt.parseInt(u8, id.?, 10) catch {
                return PrepareResult.PREPARE_INVALID_INSERT;
            };
            @memcpy(statement.row_to_insert.username[0..username.?.len], username.?);
            @memcpy(statement.row_to_insert.email[0..email.?.len], email.?);
            statement.statement_type = StatementType.STATEMENT_INSERT;

            return PrepareResult.PREPARE_SUCCESS;
        }

        if (std.mem.startsWith(u8, line, "select")) {
            statement.statement_type = StatementType.STATEMENT_SELECT;
            return PrepareResult.PREPARE_SUCCESS;
        }

        return PrepareResult.PREPARE_UNRECOGNIZED_STATEMENT;
    }

    pub fn execute(statement: *Statement) void {
        switch (statement.statement_type) {
            StatementType.STATEMENT_INSERT => {
                std.debug.print("This is where we would do an insert", .{});
            },
            StatementType.STATEMENT_SELECT => {
                std.debug.print("This is where we would do a select", .{});
            },
        }
    }
};

pub const Node = struct {
    buffer: []u8,

    pub fn init(buffer: []u8) Node {
        return Node{ .buffer = buffer };
    }

    /// Initializes a node as a leaf_node.
    pub fn initialize_leaf_node(self: *Node) void {
        self.set_num_cells(0);
        self.set_node_type(NodeType.NODE_LEAF);
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

    pub fn get_num_cells(self: *const Node) u32 {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE);
        return @bitCast(self.buffer[LEAF_NODE_NUM_CELLS_OFFSET .. LEAF_NODE_NUM_CELLS_OFFSET + LEAF_NODE_NUM_CELLS_SIZE].*);
    }

    pub fn set_num_cells(self: *Node, num_cells: u32) void {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE);
        const destination = self.buffer[LEAF_NODE_NUM_CELLS_OFFSET .. LEAF_NODE_NUM_CELLS_OFFSET + LEAF_NODE_NUM_CELLS_SIZE];
        @memcpy(destination, std.mem.asBytes(&num_cells));
    }

    pub fn get_cell(self: *const Node, cell_num: u32) []u8 {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE + (cell_num + 1) * LEAF_NODE_CELL_SIZE);

        const start_position = LEAF_NODE_HEADER_SIZE + cell_num * LEAF_NODE_CELL_SIZE;
        const end_position = LEAF_NODE_HEADER_SIZE + (cell_num + 1) * LEAF_NODE_CELL_SIZE;
        return self.buffer[start_position .. end_position + 1];
    }

    pub fn get_cell_key(self: *const Node, cell_num: u32) []u8 {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE + (cell_num + 1) * LEAF_NODE_CELL_SIZE);
        const cell = self.get_cell(cell_num);
        return cell[0..LEAF_NODE_KEY_SIZE];
    }

    pub fn get_cell_key_value(self: *const Node, cell_num: u32) u32 {
        const cell_key = self.get_cell_key(cell_num);
        return std.mem.readInt(u32, cell_key[0..4], .little);
    }

    pub fn set_cell_key(self: *Node, cell_num: u32, key: u32) void {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE + (cell_num + 1) * LEAF_NODE_CELL_SIZE);
        const cell_key = self.get_cell_key(cell_num);
        @memcpy(cell_key, std.mem.asBytes(&key));
    }

    pub fn get_cell_value(self: *const Node, cell_num: u32) []u8 {
        std.debug.assert(self.buffer.len >= LEAF_NODE_HEADER_SIZE + (cell_num + 1) * LEAF_NODE_CELL_SIZE);

        const cell = self.get_cell(cell_num);
        std.debug.assert(cell.len >= LEAF_NODE_VALUE_OFFSET + LEAF_NODE_VALUE_SIZE);

        return cell[LEAF_NODE_VALUE_OFFSET .. LEAF_NODE_VALUE_OFFSET + LEAF_NODE_VALUE_SIZE];
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

            self.pages[page_num] = p;
            return p;
        };

        return page;
    }

    pub fn get_node(self: *Pager, io: std.Io, allocator: std.mem.Allocator, page_num: u32) !Node {
        const page = try self.get_page(io, allocator, page_num);
        return Node.init(page);
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
            root_node.initialize_leaf_node();
        }

        return Table{
            .pager = pager,
            .root_page_num = 0,
        };
    }

    pub fn deinit(self: *Table, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.pager.deinit(io, allocator);
    }

    pub fn execute_statement(self: *Table, io: std.Io, allocator: std.mem.Allocator, statement: *Statement) !ExecuteResult {
        switch (statement.statement_type) {
            StatementType.STATEMENT_INSERT => {
                const root_node = try self.pager.get_node(io, allocator, self.root_page_num);
                const num_cells = root_node.get_num_cells();
                if (num_cells >= LEAF_NODE_MAX_CELLS) {
                    return ExecuteError.TableFull;
                }

                const row = &statement.row_to_insert;
                var cursor = try Cursor.find(self, io, allocator, row.id);

                if (cursor.cell_num < num_cells) {
                    const node = try cursor.table.pager.get_node(io, allocator, cursor.page_num);
                    const cell_key = node.get_cell_key_value(cursor.cell_num);
                    if (cell_key == row.id) {
                        return ExecuteError.DuplicateKey;
                    }
                }

                try cursor.insert_row(io, allocator, statement.row_to_insert.id, &statement.row_to_insert);
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
};

pub const Cursor = struct {
    table: *Table,
    page_num: u32,
    cell_num: u32,
    end_of_table: bool,

    /// Returns a cursor at the start of the table.
    pub fn start(table: *Table, io: std.Io, allocator: std.mem.Allocator) !Cursor {
        const root_node = try table.pager.get_node(io, allocator, table.root_page_num);

        return Cursor{
            .table = table,
            .page_num = table.root_page_num,
            .cell_num = 0,
            .end_of_table = root_node.get_num_cells() == 0,
        };
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

    pub fn find(table: *Table, io: std.Io, allocator: std.mem.Allocator, key: u32) !Cursor {
        var cursor = try Cursor.start(table, io, allocator);
        var root_node = try cursor.table.pager.get_node(io, allocator, table.root_page_num);

        if (root_node.get_node_type() == NodeType.NODE_LEAF) {
            try cursor.find_in_leaf_node(root_node, key);
        } else {
            std.debug.print("Searching in internal nodes is not implemented yet!", .{});
            return CursorError.UnimplementedNodeSplitting;
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

    /// Returns the current cell in bytes present at the current cursor position.
    pub fn value(self: *Cursor, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        const node = try self.table.pager.get_node(io, allocator, self.page_num);
        return node.get_cell_value(self.cell_num);
    }

    /// advances the cursor to the next cell in the page.
    pub fn advance(self: *Cursor, io: std.Io, allocator: std.mem.Allocator) !void {
        const node = try self.table.pager.get_node(io, allocator, self.page_num);

        self.cell_num += 1;
        self.end_of_table = self.cell_num >= node.get_num_cells();
    }

    pub fn insert_row(self: *Cursor, io: std.Io, allocator: std.mem.Allocator, key: u32, row: *const Row) !void {
        var node = try self.table.pager.get_node(io, allocator, self.page_num);
        const num_cells = node.get_num_cells();

        if (num_cells >= LEAF_NODE_MAX_CELLS) {
            std.debug.print("Need to implement splitting a full node", .{});
            return CursorError.UnimplementedNodeSplitting;
        }

        if (self.cell_num < num_cells) {
            var cell_num = num_cells;
            while (cell_num > self.cell_num) : (cell_num -= 1) {
                @memcpy(node.get_cell(cell_num), node.get_cell(cell_num - 1));
            }
        }

        node.set_num_cells(num_cells + 1);
        node.set_cell_key(self.cell_num, key);
        serialize_row(row, node.get_cell_value(self.cell_num));
    }
};

pub fn serialize_row(row: *const Row, destination: []u8) void {
    @memcpy(destination, std.mem.asBytes(row));
}

pub fn deserialize_row(source: []u8) !Row {
    const row = std.mem.bytesToValue(Row, source);
    return row;
}

pub fn do_meta_command(line: []const u8) MetaCommandResult {
    if (std.mem.eql(u8, line, ".exit")) {
        return MetaCommandResult.META_COMMAND_EXIT;
    } else {
        return MetaCommandResult.META_COMMAND_UNRECOGNIZED_COMMAND;
    }
}

pub fn open_database(io: std.Io, path: []const u8) !Table {
    return try .init(io, path);
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

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var table: Table = try Table.init(io, allocator, database_path.?);
    defer table.deinit(io, allocator) catch |err| {
        std.debug.print("Failed to deinitialize the table: {}\n", .{err});
    };

    while (true) {
        try stdout_writer.print("zqlite> ", .{});
        try stdout_writer.flush();

        const line = try stdin_reader.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");

        if (trimmed.len == 0) {
            continue;
        }

        if (trimmed[0] == '.') {
            switch (do_meta_command(trimmed)) {
                MetaCommandResult.META_COMMAND_EXIT => {
                    return;
                },
                MetaCommandResult.META_COMMAND_UNRECOGNIZED_COMMAND => {
                    try stdout_writer.print("Unrecognized Command {s}", .{trimmed});
                    try stdout_writer.flush();
                },
            }
        } else {
            var statement: Statement = .{ .statement_type = undefined, .row_to_insert = undefined };
            switch (statement.prepare_statement(trimmed)) {
                PrepareResult.PREPARE_SUCCESS => {
                    _ = table.execute_statement(io, allocator, &statement) catch |err| {
                        switch (err) {
                            ExecuteError.TableFull => {
                                try stdout_writer.print("ERROR: Reached max table size", .{});
                                try stdout_writer.flush();
                            },
                            ExecuteError.DuplicateKey => {
                                try stdout_writer.print("ERROR: Cannot insert a duplicate key", .{});
                                try stdout_writer.flush();
                            },
                            else => {
                                try stdout_writer.print("ERROR: Unable to execute statement: {any}", .{err});
                                try stdout_writer.flush();
                            },
                        }
                    };
                },
                PrepareResult.PREPARE_UNRECOGNIZED_STATEMENT => {
                    try stdout_writer.print("Unrecognized keyword at the start {s}", .{trimmed});
                    try stdout_writer.flush();
                },
                PrepareResult.PREPARE_INVALID_INSERT => {
                    try stdout_writer.print("Syntax error. Could not parse statement", .{});
                    try stdout_writer.flush();
                },
            }
        }

        try stdout_writer.print("\n", .{});
        try stdout_writer.flush();
    }
}
