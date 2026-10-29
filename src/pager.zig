const std = @import("std");

pub const PagerError = std.Io.File.LengthError || error{InvalidDatabaseFileLength} || PageGetError;
pub const PageGetError = std.Io.File.ReadPositionalError || error{
    MaxPageExceeded,
    OutOfMemory,
    InvalidPageSize,
    PageNotAllocated,
};

pub const Pager = @This();

// Static fields.
pub const page_size = 4096;
pub const max_pages = 100;
pub const Page = [page_size]u8;

// Struct fields
io: std.Io,
allocator: std.mem.Allocator,
pages: [max_pages]?*Page,
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
        .pages = @splat(null),
    };
}

pub fn deinit(self: *Pager) void {
    self.flush();
    self.database_file.close(self.io);
}

/// Returns the page at the given index.
/// Allocates a new page if the page does not already exist in cache.
pub fn get_page(self: *Pager, index: u32) PageGetError!*Page {
    if (index >= max_pages) return PageGetError.MaxPageExceeded;

    const page = self.pages[index] orelse {
        const p = self.allocator.create(Page) catch |err| {
            std.debug.print("Error: Ran out of memory: {any}\n", .{err});
            return PageGetError.OutOfMemory;
        };

        const offset = index * page_size;
        _ = try self.database_file.readPositional(self.io, &.{p}, offset);

        if (index >= self.num_pages) {
            self.num_pages += 1;
        }

        self.pages[index] = p;
        return p;
    };

    return page;
}

/// Returns a page if and only if it already exists within the cache.
pub fn read_page(self: *Pager, index: u32) PageGetError!*Page {
    if (index >= max_pages) return PageGetError.MaxPageExceeded;
    const page = self.pages[index];

    if (page == null) return PageGetError.PageNotAllocated;
    return page.?;
}

pub fn flush(self: *Pager) void {
    for (0..self.num_pages + 1) |index| {
        if (self.pages[index]) |page| {
            const offset = index * page_size;
            _ = self.database_file.writePositional(self.io, &.{page}, offset) catch |err| {
                std.debug.print("Error: Unable to write to file for page: {d}\n", .{index});
                std.debug.print("Error: {any}\n", .{err});
            };

            self.allocator.destroy(page);
        }
    }
}
