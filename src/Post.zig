const std = @import("std");

pub const FileType = enum {
    gif,
    jpg,
    mp4,
    png,
    swf,
    webm,
    zip,

    pub fn toMime(self: @This()) [:0]const u8 {
        return switch (self) {
            .gif => "image/gif",
            .jpg => "image/jpeg",
            .mp4 => "video/mp4",
            .png => "image/png",
            .swf => "application/vnd.adobe.flash-movie",
            .webm => "video/webm",
            .zip => "application/zip",
        };
    }
};

id: u64,
is_safe: bool,
file_type: FileType,
data: ?[]u8 = null,

allocator: std.mem.Allocator,

const Self = @This();

pub fn clear(self: *Self) void {
    if (self.data) |exists|
        self.allocator.free(exists);

    self.data = null;
}
