const RawPost = @import("RawPost.zig");
const std = @import("std");

// REQUIRED
pub const bot_name = "thisisa_bot";

pub const query = [_][]const u8{
    "",
};

// REQUIRED
pub const pleroma_host = "";
pub const post_delay = 720; // in minutes

pub fn filter(post: RawPost) bool {
    _ = post;
    return false;
}
