const std = @import("std");
const Io = std.Io;

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
        try stdout_writer.print("zqlite>", .{});
        try stdout_writer.flush();

        const line = try stdin_reader.takeDelimiterInclusive('\n');

        // In windows, newline character in stdin includes CRLF.
        if (std.mem.eql(u8, line, ".exit\r\n")) {
            std.process.exit(0);
        } else {
            try stdout_writer.print("Unknown command", .{});
            try stdout_writer.flush();
        }

        try stdout_writer.print("\n", .{});
        try stdout_writer.flush();
    }
}
