const c = @import("c.zig");
const custom = @import("custom.zig");
const std = @import("std");
const Post = @import("Post.zig");

id: u64,
score: i16,
source: []u8,
rating: [1]u8,
image_width: u16,
image_height: u16,
file_ext: []u8,
tag_count_general: u16,
tag_count_artist: u8,
tag_count_character: u8,
tag_count_copyright: u8,
tag_count_meta: u8,
file_size: usize,
is_pending: bool,
is_flagged: bool,
is_deleted: bool,
is_banned: bool,
pixiv_id: ?u64,
tag_string_general: []u8,
tag_string_artist: []u8,
tag_string_character: []u8,
tag_string_copyright: []u8,
tag_string_meta: []u8,
file_url: []u8,
large_file_url: []u8,

const Self = @This();

pub fn filter(self: Self) bool {
    if (@hasDecl(custom, "filter"))
        return custom.filter(self);

    return false;
}

pub fn toPost(self: Self, allocator: std.mem.Allocator, request: *c.CURL) !Post {
    var file_type: Post.FileType = switch (self.file_ext[0]) {
        'g' => .gif,
        'j' => .jpg,
        'm' => .mp4,
        'p' => .png,
        's' => .swf,
        'w' => .webm,
        'z' => .zip,
        else => unreachable,
    };

    var buffer: [256]u8 = undefined;
    var ptr: *const []u8 = undefined;

    if (file_type == .zip) {
        ptr = &self.large_file_url;
        file_type = .webm;
    } else ptr = &self.file_url;

    const new_url = std.fmt.bufPrintZ(&buffer, "{s}", .{ptr.*}) catch unreachable;

    _ = c.curl_easy_setopt(request, c.CURLOPT_URL, new_url.ptr);

    if (c.curl_easy_perform(request) != c.CURLE_OK)
        return error.FailedRequest;

    var response_code: c_long = undefined;
    _ = c.curl_easy_getinfo(request, c.CURLINFO_RESPONSE_CODE, &response_code);

    if (response_code >= 400)
        return error.StatusNot200;

    // REMEMBER that the image data still hasn't been copied from `danbooru_response`.
    return Post{
        .id = self.id,
        .file_type = file_type,
        .is_safe = if (self.rating[0] == 's') true else false,

        .allocator = allocator,
    };
}
