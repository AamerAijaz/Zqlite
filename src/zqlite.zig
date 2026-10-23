const std = @import("std");
const Io = std.Io;

const MAX_PAGES = 100;
const PAGE_SIZE = 4096;
const ROW_SIZE = @sizeOf(Row);
const ROWS_PER_PAGE = PAGE_SIZE / ROW_SIZE;
const TABLE_MAX_ROWS = ROWS_PER_PAGE * MAX_PAGES;

const MetaCommandResult = enum { META_COMMAND_EXIT, META_COMMAND_UNRECOGNIZED_COMMAND };
const PrepareResult = enum { PREPARE_SUCCESS, PREPARE_UNRECOGNIZED_STATEMENT, PREPARE_INVALID_INSERT };
const StatementType = enum { STATEMENT_INSERT, STATEMENT_SELECT };
const ExecuteResult = enum { EXECUTE_SUCCESS, EXECUTE_TABLE_FULL };

pub const PagerError = error{
    MaxPageExceeded,
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

pub const Page = [PAGE_SIZE]u8;
pub const Pager = struct {
    database_file: std.Io.File,
    database_file_length: u64,
    pages: [MAX_PAGES]?*Page = @splat(null), // An in-memory cache of the pages fetched or inserted.

    pub fn init(io: std.Io, path: []const u8) !Pager {
        const database_file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{
            .mode = .read_write,
        });

        const database_file_length = try database_file.length(io);

        return Pager{ .database_file = database_file, .database_file_length = database_file_length, .pages = @splat(null) };
    }

    pub fn deinit(self: *Pager, io: std.Io, allocator: std.mem.Allocator, num_rows: u32) !void {
        const num_full_pages = num_rows / ROWS_PER_PAGE;

        for (0..num_full_pages) |page_num| {
            if (self.pages[page_num]) |page| {
                const offset = page_num * PAGE_SIZE;
                _ = try self.database_file.writePositional(io, &.{page.*[0..]}, offset);

                allocator.destroy(page);
            }
        }

        const additional_rows = num_rows % ROWS_PER_PAGE;
        if (additional_rows != 0) {
            if (self.pages[num_full_pages]) |page| {
                const buffer = page[0 .. additional_rows * ROW_SIZE];
                _ = try self.database_file.writePositional(io, &.{buffer}, num_full_pages * PAGE_SIZE);
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
};

pub const Table = struct {
    num_rows: u32 = 0,
    pages: [MAX_PAGES]?*Page = @splat(null),
    pager: Pager,

    pub fn init(io: std.Io, path: []const u8) !Table {
        const pager = try Pager.init(io, path);
        const num_rows = pager.database_file_length / ROW_SIZE;

        return Table{
            .pager = pager,
            .pages = @splat(null),
            .num_rows = @intCast(num_rows),
        };
    }

    pub fn deinit(self: *Table, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.pager.deinit(io, allocator, self.num_rows);
    }

    pub fn row_slot(self: *Table, io: std.Io, allocator: std.mem.Allocator, row_num: u32) ![]u8 {
        const page_num: u32 = row_num / ROWS_PER_PAGE;
        const page = try self.pager.get_page(io, allocator, page_num);

        const row_offset = row_num % ROWS_PER_PAGE;
        const byte_offset = row_offset * ROW_SIZE; // Get the offset to the row within the page.
        const remaining_page = page[byte_offset..];

        std.debug.assert(remaining_page.len >= ROW_SIZE);
        return remaining_page[0..ROW_SIZE];
    }

    pub fn execute_statement(self: *Table, io: std.Io, allocator: std.mem.Allocator, statement: *Statement) !ExecuteResult {
        switch (statement.statement_type) {
            StatementType.STATEMENT_INSERT => {
                if (self.num_rows > TABLE_MAX_ROWS) {
                    return ExecuteResult.EXECUTE_TABLE_FULL;
                }

                const slot = try self.row_slot(io, allocator, self.num_rows);
                try serialize_row(&statement.row_to_insert, slot);
                self.num_rows += 1;
            },
            StatementType.STATEMENT_SELECT => {
                for (0..self.num_rows) |i| {
                    const slot = try self.row_slot(io, allocator, @intCast(i));
                    const row = try deserialize_row(slot);
                    std.debug.print("Row - {d}, {s}, {s}\n", .{ row.id, row.username, row.email });
                }
            },
        }

        std.debug.print("Executed", .{});
        return ExecuteResult.EXECUTE_SUCCESS;
    }
};

pub fn serialize_row(row: *Row, destination: []u8) !void {
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

    var table: Table = try Table.init(io, "database.db");

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
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
                    switch (try table.execute_statement(io, allocator, &statement)) {
                        ExecuteResult.EXECUTE_SUCCESS => {},
                        ExecuteResult.EXECUTE_TABLE_FULL => {
                            try stdout_writer.print("ERROR: Reached max table size", .{});
                            try stdout_writer.flush();
                        },
                    }
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
