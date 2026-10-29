const std = @import("std");

pub const PrepareError = error{
    InvalidInsert,
    UnrecognizedStatement,
};
pub const StatementType = enum { Insert, Select };

pub const Row = extern struct {
    id: u32,
    username: [32]u8,
    email: [255]u8,
};
pub const RowSize = @sizeOf(Row);

pub const Statement = struct {
    statement_type: StatementType,
    row_to_insert: Row,

    pub fn execute(statement: *Statement) void {
        switch (statement.statement_type) {
            StatementType.Insert => {
                std.debug.print("This is where we would do an insert", .{});
            },
            StatementType.Select => {
                std.debug.print("This is where we would do a select", .{});
            },
        }
    }
};

pub fn prepare_statement(line: []const u8) PrepareError!Statement {
    var statement: Statement = undefined;
    if (std.mem.startsWith(u8, line, "insert")) {
        const remaining = std.mem.cutPrefix(u8, line, "insert");

        if (remaining == null) {
            return PrepareError.UnrecognizedStatement;
        }

        if (remaining.?.len == 0 or remaining.?[0] != ' ') {
            return PrepareError.InvalidInsert;
        }

        const trimmed = std.mem.trim(u8, remaining.?, " ");
        var iterator = std.mem.tokenizeScalar(u8, trimmed, ' ');

        const id = iterator.next();
        if (id == null) {
            return PrepareError.InvalidInsert;
        }

        const username = iterator.next();
        if (username == null or username.?.len > 32) {
            return PrepareError.InvalidInsert;
        }

        const email = iterator.next();
        if (email == null or email.?.len > 255) {
            return PrepareError.InvalidInsert;
        }

        statement.row_to_insert = Row{ .id = 0, .email = std.mem.zeroes([255]u8), .username = std.mem.zeroes([32]u8) };
        statement.row_to_insert.id = std.fmt.parseInt(u8, id.?, 10) catch {
            return PrepareError.InvalidInsert;
        };
        @memcpy(statement.row_to_insert.username[0..username.?.len], username.?);
        @memcpy(statement.row_to_insert.email[0..email.?.len], email.?);
        statement.statement_type = StatementType.Insert;

        return statement;
    } else if (std.mem.startsWith(u8, line, "select")) {
        statement.statement_type = StatementType.Select;
        return statement;
    } else {
        return PrepareError.UnrecognizedStatement;
    }
}
