const std = @import("std");
const Io = std.Io;

const MetaCommandResult = enum { META_COMMAND_SUCCESS, META_COMMAND_UNRECOGNIZED_COMMAND };
const PrepareResult = enum { PREPARE_SUCCESS, PREPARE_UNRECOGNIZED_STATEMENT };
const StatementType = enum { STATEMENT_INSERT, STATEMENT_SELECT };

pub const Statement = struct {
    statement_type: StatementType,
    pub fn prepare_statement(statement: *Statement, line: []const u8) PrepareResult {
        if (std.mem.startsWith(u8, line, "insert")) {
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

pub fn do_meta_command(line: []const u8) MetaCommandResult {
    if (std.mem.eql(u8, line, ".exit")) {
        std.process.exit(0);
    } else {
        return MetaCommandResult.META_COMMAND_UNRECOGNIZED_COMMAND;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
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
            switch (do_meta_command(trimmed)) {
                MetaCommandResult.META_COMMAND_SUCCESS => {},
                MetaCommandResult.META_COMMAND_UNRECOGNIZED_COMMAND => {
                    try stdout_writer.print("Unrecognized Command {s}", .{trimmed});
                    try stdout_writer.flush();
                },
            }
        }

        var statement: Statement = .{ .statement_type = undefined };
        switch (statement.prepare_statement(trimmed)) {
            PrepareResult.PREPARE_SUCCESS => {
                statement.execute();
            },
            PrepareResult.PREPARE_UNRECOGNIZED_STATEMENT => {
                try stdout_writer.print("Unrecognized keyword at the start {s}", .{trimmed});
                try stdout_writer.flush();
            },
        }

        try stdout_writer.print("\n", .{});
        try stdout_writer.flush();
    }
}
