const std = @import("std");

pub const PagerError = std.Io.File.LengthError || error{
    InvalidDatabaseFileLength,
};

pub const Pager = @This();

// Static fields.
pub const page_size: u32 = 4096;

// Struct fields
io: std.Io,
allocator: std.mem.Allocator,
database_file: std.Io.File,
database_file_len: u64,
num_pages: u32,

pub fn init(io: std.Io, allocator: std.mem.Allocator, database_file: std.Io.File) PagerError!Pager {
    const database_file_len = try database_file.length(io);
    if (database_file_len % page_size != 0) {
        std.debug.print("Error: Database file length must be a multiple of {d}\n", .{page_size});
        return PagerError.InvalidDatabaseFileLength;
    }

    const num_pages = database_file_len / page_size;

    return Pager{
        .io = io,
        .allocator = allocator,
        .database_file = database_file,
        .database_file_len = database_file_len,
        .num_pages = @intCast(num_pages),
    };
}

pub fn deinit(self: *Pager) void {
    self.database_file.close(self.io);
}
