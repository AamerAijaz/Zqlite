const std = @import("std");
const zqlite = @import("zqlite.zig");
const statement = @import("statement.zig");
const Statement = statement.Statement;
const PrepareError = statement.PrepareError;

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
