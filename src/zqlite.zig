const std = @import("std");
const cursor = @import("cursor.zig");

pub const ConnectError = std.Io.File.OpenError || cursor.CursorError;
pub const MetaCommandResult = enum { Exit, Success, UnrecognizedCommand };

pub const Connection = struct {
    cursor: cursor.Cursor,

    pub fn execute_meta_command(_: *Connection, line: []const u8) MetaCommandResult {
        if (std.mem.eql(u8, line, ".exit")) {
            return MetaCommandResult.Exit;
        }
        return MetaCommandResult.UnrecognizedCommand;
    }

    pub fn close(self: *Connection) void {
        self.cursor.deinit();
    }
};

pub fn connect(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) ConnectError!Connection {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, db_path, .{ .mode = .read_write }) catch |err| {
        std.debug.print("Error: Unable to open database file, path: {s}\n", .{db_path});
        std.debug.print("Error: {any}\n", .{err});
        return err;
    };

    const c = try cursor.init(io, allocator, file);
    return Connection{
        .cursor = c,
    };
}
