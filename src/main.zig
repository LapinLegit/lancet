const auth = @import("auth.zig");
const builtin = @import("builtin");
const c = @import("c.zig");
const custom = @import("custom.zig");
const Post = @import("Post.zig");
const RawPost = @import("RawPost.zig");
const std = @import("std");

const closelog = @import("daemon.zig").closelog;
const daemonize = @import("daemon.zig").daemonize;
const syslog = @import("daemon.zig").syslog;

comptime {
    if (custom.bot_name.len == 0)
        @compileError("custom.bot_name cannot be empty!");
}

const error_delay = 1 * std.time.ns_per_min;
const danbooru_posts_limit = 30;

var exit_code: u8 = 0;

inline fn exitCode(code: u8) u8 {
    exit_code = code;
    return code;
}

var curl_global_init: u1 = 0;
var main_allocator: std.mem.Allocator = undefined;

var danbooru_post_request: ?*c.CURL = null;
var danbooru_image_request: ?*c.CURL = null;
var pleroma_media_request: ?*c.CURL = null;
var pleroma_status_request: ?*c.CURL = null;

var mime: ?*c.curl_mime = null;
var part: *c.curl_mimepart = undefined;

var danbooru_response: ?std.ArrayList(u8) = null;
var pleroma_response: ?std.ArrayList(u8) = null;

var pleroma_header: ?*c.curl_slist = null;

var danbooru_posts_mutex = std.Thread.Mutex{};
var danbooru_posts: ?std.ArrayList(Post) = null;
var pending_posts: ?std.ArrayList(Post) = null;

pub fn main() u8 {
    daemonize(custom.bot_name);

    main_allocator = if (builtin.link_libc)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    _ = std.os.sigaction(std.os.SIG.INT, &.{
        .handler = .{ .sigaction = deinitOnSigint },
        .mask = std.os.empty_sigset,
        .flags = std.os.SA.SIGINFO,
    }, null);

    defer cleanup();

    const danbooru_url = comptime block: {
        var search_query: []const u8 = "";
        for (custom.query) |query| {
            if (query.len == 0) continue;
            search_query = search_query ++ query ++ "+";
        }

        break :block std.fmt.comptimePrint("https://danbooru.donmai.us/posts.json?tags={s}", .{search_query});
    };

    const curl_code = c.curl_global_init(c.CURL_GLOBAL_ALL);
    if (curl_code != c.CURLE_OK) {
        syslog(.err, "failed to initialize curl ({d})", .{curl_code});
        return exitCode(1);
    }

    curl_global_init = 1;

    danbooru_post_request = c.curl_easy_init() orelse return exitCode(1);
    pleroma_media_request = c.curl_easy_init() orelse return exitCode(1);

    danbooru_response = std.ArrayList(u8).init(main_allocator);
    pleroma_response = std.ArrayList(u8).init(main_allocator);

    danbooru_posts = std.ArrayList(Post).init(main_allocator);
    pending_posts = std.ArrayList(Post).init(main_allocator);

    {
        _ = c.curl_easy_setopt(danbooru_post_request.?, c.CURLOPT_WRITEFUNCTION, writeFunc);
        _ = c.curl_easy_setopt(danbooru_post_request.?, c.CURLOPT_WRITEDATA, &(danbooru_response.?));

        danbooru_image_request = c.curl_easy_duphandle(danbooru_post_request.?) orelse return exitCode(1);

        if (auth.danbooru_api_key.len > 0)
            _ = c.curl_easy_setopt(danbooru_post_request.?, c.CURLOPT_USERPWD, auth.danbooru_api_key);

        _ = c.curl_easy_setopt(danbooru_post_request.?, c.CURLOPT_URL, danbooru_url);
    }

    {
        if (auth.pleroma_access_token.len == 0) @compileError("access token is empty!");

        pleroma_header = c.curl_slist_append(null, "Authorization: Bearer " ++ auth.pleroma_access_token) orelse return exitCode(1);

        _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_HTTPHEADER, pleroma_header.?);
        _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_WRITEFUNCTION, writeFunc);
        _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_WRITEDATA, &(pleroma_response.?));
        _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_POST, @as(c_long, 1));

        pleroma_status_request = c.curl_easy_duphandle(pleroma_media_request.?) orelse return exitCode(1);

        if (custom.pleroma_host.len == 0) @compileError("empty pleroma host!");

        {
            const media_url = std.fs.path.joinZ(main_allocator, &[_][]const u8{
                custom.pleroma_host,
                "/api/v2/media",
            }) catch |err| {
                syslog(.err, "failed to set media_url ({s})", .{@errorName(err)});
                return exitCode(1);
            };
            defer main_allocator.free(media_url);

            const status_url = std.fs.path.joinZ(main_allocator, &[_][]const u8{
                custom.pleroma_host,
                "/api/v1/statuses",
            }) catch |err| {
                syslog(.err, "failed to set status_url ({s})", .{@errorName(err)});
                return exitCode(1);
            };
            defer main_allocator.free(status_url);

            _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_URL, media_url.ptr);
            _ = c.curl_easy_setopt(pleroma_status_request.?, c.CURLOPT_URL, status_url.ptr);
        }

        mime = c.curl_mime_init(pleroma_media_request.?) orelse return exitCode(1);
        part = c.curl_mime_addpart(mime.?) orelse return exitCode(1);
    }

    _ = std.Thread.spawn(.{}, populatePosts, .{}) catch |err| {
        syslog(.err, "failed to spawn thread ({s})", .{@errorName(err)});
        return exitCode(1);
    };

    postToFediverse();

    return 0;
}

const MediaResponse = struct {
    id: []u8,
};

fn postToFediverse() noreturn {
    std.time.sleep(30 * std.time.ns_per_s);

    syslog(.notice, "thread begins sending pending posts to fediverse", .{});

    var buffer: [1024]u8 = undefined;
    var db_posts_empty: u1 = 0;
    var found_error: u1 = 0;

    root: while (true) {
        {
            danbooru_posts_mutex.lock();
            defer danbooru_posts_mutex.unlock();

            if (danbooru_posts.?.items.len == 0)
                db_posts_empty = 1
            else
                db_posts_empty = 0;
        }

        if (db_posts_empty > 0) {
            std.time.sleep(1 * std.time.ns_per_min);
            continue :root;
        }

        {
            danbooru_posts_mutex.lock();
            defer danbooru_posts_mutex.unlock();

            pending_posts = std.ArrayList(Post).fromOwnedSlice(main_allocator, danbooru_posts.?.toOwnedSlice());
        }
        defer pending_posts.?.clearAndFree();

        pending: while (pending_posts.?.popOrNull()) |*post| {
            defer post.clear();

            const file_name = std.fmt.bufPrintZ(&buffer, "{d}.{s}", .{ post.id, @tagName(post.file_type) }) catch unreachable;

            _ = c.curl_mime_data(part, post.data.?.ptr, post.data.?.len);
            _ = c.curl_mime_filename(part, file_name);
            _ = c.curl_mime_type(part, post.file_type.toMime());
            _ = c.curl_mime_name(part, "file");

            _ = c.curl_easy_setopt(pleroma_media_request.?, c.CURLOPT_MIMEPOST, mime.?);

            var response_slice: []u8 = undefined;

            inner: while (true) {
                if (found_error > 0) {
                    std.time.sleep(error_delay);
                    found_error = 0;
                }
                const curl_code = c.curl_easy_perform(pleroma_media_request.?);
                if (curl_code > c.CURLE_OK) {
                    syslog(.err, "postToFediverse(): pleroma_media_request failed! ({d})", .{curl_code});
                    found_error = 1;
                    continue :inner;
                }
                var response_code: c_long = undefined;
                _ = c.curl_easy_getinfo(pleroma_media_request.?, c.CURLINFO_RESPONSE_CODE, &response_code);

                if (response_code >= 400) {
                    syslog(.err, "postToFediverse(): pleroma_media_request invalid response code! ({d})\n", .{response_code});
                    pleroma_response.?.clearAndFree();
                    found_error = 1;
                    continue :inner;
                }
                response_slice = pleroma_response.?.toOwnedSlice();
                break :inner;
            }
            defer main_allocator.free(response_slice);

            const options = std.json.ParseOptions{
                .allocator = main_allocator,
                .duplicate_field_behavior = .UseFirst,
                .ignore_unknown_fields = true,
            };

            const media = std.json.parse(MediaResponse, &std.json.TokenStream.init(response_slice), options) catch |err| {
                syslog(.err, "postToFediverse(): std.json.parse failed! ({s})", .{@errorName(err)});
                syslog(.err, "postToFediverse(): skipping post #{d}", .{post.id});
                continue :pending;
            };
            defer std.json.parseFree(MediaResponse, media, options);

            const post_form0 = comptime block: {
                var foo: []const u8 = "content_type=text%2Fmarkdown&";
                foo = foo ++ "media_ids[]={s}&";
                foo = foo ++ "sensitive={}&";
                foo = foo ++ "status=%5B.%5D(http%3A%2F%2Fdanbooru.donmai.us%2Fposts%2F{d})&";
                foo = foo ++ "visibility=unlisted";
                break :block foo;
            };
            const post_form1 = std.fmt.bufPrintZ(&buffer, post_form0, .{
                media.id,
                !post.is_safe,
                post.id,
            }) catch unreachable;

            _ = c.curl_easy_setopt(pleroma_status_request.?, c.CURLOPT_POSTFIELDS, post_form1.ptr);

            inner: while (true) {
                if (found_error > 0) {
                    std.time.sleep(error_delay);
                    found_error = 0;
                }
                const curl_code = c.curl_easy_perform(pleroma_status_request.?);
                if (curl_code != c.CURLE_OK) {
                    syslog(.err, "postToFediverse(): pleroma_status_request failed! ({d})", .{curl_code});
                    found_error = 1;
                    continue :inner;
                }
                defer pleroma_response.?.clearAndFree();

                var response_code: c_long = undefined;
                _ = c.curl_easy_getinfo(pleroma_status_request.?, c.CURLINFO_RESPONSE_CODE, &response_code);

                if (response_code >= 400) {
                    syslog(.err, "postToFediverse(): pleroma_status_request invalid response code! ({d})\n", .{response_code});
                    found_error = 1;
                    continue :inner;
                }
                break :inner;
            }
            syslog(.notice, "status with post #{d} successfully posted!", .{post.id});
            std.time.sleep(custom.post_delay * std.time.ns_per_min);
        }
    }
}

fn populatePosts() noreturn {
    syslog(.notice, "thread begins populating posts", .{});

    var found_error: u1 = 0;
    var posts_full: u1 = 0;

    root: while (true) {
        if (found_error > 0) {
            std.time.sleep(error_delay);
            found_error = 0;
        }

        {
            danbooru_posts_mutex.lock();
            defer danbooru_posts_mutex.unlock();
            if (danbooru_posts.?.items.len > danbooru_posts_limit)
                posts_full = 1
            else
                posts_full = 0;
        }

        if (posts_full > 0) {
            std.time.sleep(1 * std.time.ns_per_min);
            continue :root;
        }
        var response_slice: []u8 = undefined;

        {
            const curl_code = c.curl_easy_perform(danbooru_post_request.?);
            if (curl_code != c.CURLE_OK) {
                syslog(.err, "populatePosts(): curl_easy_perform failed! ({d})", .{curl_code});
                found_error = 1;
                continue :root;
            }
            var response_code: c_long = undefined;
            _ = c.curl_easy_getinfo(danbooru_post_request.?, c.CURLINFO_RESPONSE_CODE, &response_code);

            if (response_code >= 400) {
                syslog(.err, "populatePosts(): invalid response code! ({d})\n", .{response_code});
                danbooru_response.?.clearAndFree();
                found_error = 1;
                continue :root;
            }
            response_slice = danbooru_response.?.toOwnedSlice();
        }
        defer main_allocator.free(response_slice);

        var token_stream = std.json.TokenStream.init(response_slice);

        var begin: ?usize = null;
        var end: usize = undefined;

        while (token_stream.next() catch |err| {
            syslog(.err, "populatePosts(): std.json.TokenStream.next failed! ({s})", .{@errorName(err)});
            found_error = 1;
            continue :root;
        }) |token| {
            switch (token) {
                .ObjectBegin => begin = token_stream.i - 1,
                .ObjectEnd => {
                    defer begin = null;
                    end = token_stream.i;

                    if (begin == null) {
                        syslog(.err, "populatePosts(): invalid JSON!", .{});
                        found_error = 1;
                        continue :root;
                    }

                    const options = std.json.ParseOptions{
                        .allocator = main_allocator,
                        .duplicate_field_behavior = .UseFirst,
                        .ignore_unknown_fields = true,
                    };

                    @setEvalBranchQuota(20000);
                    const r = std.json.parse(RawPost, &std.json.TokenStream.init(token_stream.slice[begin.?..end]), options) catch |err| {
                        syslog(.err, "populatePosts(): std.json.parse failed! ({s})", .{@errorName(err)});
                        found_error = 1;
                        continue :root;
                    };
                    defer std.json.parseFree(RawPost, r, options);

                    if (!r.filter()) {
                        var post = r.toPost(main_allocator, danbooru_image_request.?) catch |err| {
                            syslog(.err, "populatePosts(): r.toPost failed! ({s})", .{@errorName(err)});
                            found_error = 1;
                            continue :root;
                        };
                        // toPost() above will also retrieve image data to `danbooru_response`.
                        post.data = danbooru_response.?.toOwnedSlice();
                        {
                            danbooru_posts_mutex.lock();
                            defer danbooru_posts_mutex.unlock();
                            danbooru_posts.?.append(post) catch |err| {
                                syslog(.err, "populatePosts(): danbooru_posts.?.append failed! ({s})", .{@errorName(err)});
                                found_error = 1;
                                continue :root;
                            };
                        }
                        syslog(.info, "found post id #{d}", .{post.id});
                    }
                },
                else => {},
            }
        }

        danbooru_posts_mutex.lock();
        defer danbooru_posts_mutex.unlock();
        syslog(.info, "found {d} posts so far", .{danbooru_posts.?.items.len});
    }
}

fn cleanup() void {
    syslog(.notice, "cleaning up...", .{});

    if (mime) |exists| c.curl_mime_free(exists);
    if (pleroma_header) |exists| c.curl_slist_free_all(exists);

    if (danbooru_response) |exists| exists.deinit();
    if (pleroma_response) |exists| exists.deinit();

    if (danbooru_posts) |exists| {
        for (exists.items) |*post|
            post.clear();
        exists.deinit();
    }

    if (pleroma_media_request) |exists| c.curl_easy_cleanup(exists);
    if (pleroma_status_request) |exists| c.curl_easy_cleanup(exists);
    if (danbooru_image_request) |exists| c.curl_easy_cleanup(exists);
    if (danbooru_post_request) |exists| c.curl_easy_cleanup(exists);
    if (curl_global_init > 0) c.curl_global_cleanup();

    std.fs.cwd().deleteFile("/tmp/" ++ custom.bot_name ++ ".pid") catch |err| switch (err) {
        error.FileNotFound => {},
        else => syslog(.err, "failed to delete pidfile ({s})", .{@errorName(err)}),
    };

    if (exit_code > 0)
        syslog(.notice, "daemon terminated with an ERROR", .{})
    else
        syslog(.notice, "daemon terminated with NO PROBLEM", .{});

    closelog();
}

fn writeFunc(
    data: *anyopaque,
    size: c_uint,
    nmemb: c_uint,
    user_data: *anyopaque,
) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    const typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

fn deinitOnSigint(signo: c_int, info: *const std.os.siginfo_t, context: ?*const anyopaque) callconv(.C) void {
    _ = signo;
    _ = info;
    _ = context;

    cleanup();

    _ = std.os.sigaction(std.os.SIG.INT, &.{
        .handler = .{ .sigaction = std.os.SIG.DFL },
        .mask = std.os.empty_sigset,
        .flags = std.os.SA.SIGINFO,
    }, null);

    std.os.kill(std.os.linux.getpid(), std.os.SIG.INT) catch unreachable;
}
