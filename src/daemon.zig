const std = @import("std");

var has_daemonized: u1 = 0;
var log_open: u1 = 0;

const Level = enum(c_int) {
    emerg = 0,
    alert,
    crit,
    err,
    warning,
    notice,
    info,
    debug,
};

pub fn syslog(level: Level, comptime format: []const u8, args: anytype) void {
    if (log_open == 0) return;

    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, format, args) catch return;

    std.c.syslog(@enumToInt(level), msg);
}

pub fn closelog() void {
    if (log_open == 1) {
        std.c.closelog();
        log_open = 0;
    }
}

pub fn daemonize(comptime name: ?[:0]const u8) void {
    if (has_daemonized == 1) return;

    const EXIT_FAILURE = 1;
    const EXIT_SUCCESS = 0;

    var pid = std.os.fork() catch unreachable;

    if (pid < 0)
        std.os.exit(EXIT_FAILURE);
    if (pid > 0)
        std.os.exit(EXIT_SUCCESS);

    if (std.os.linux.syscall0(std.os.linux.SYS.setsid) < 0)
        std.os.exit(EXIT_FAILURE);

    for ([_]u6{ std.os.SIG.CHLD, std.os.SIG.HUP }) |value| {
        _ = std.os.sigaction(value, &.{
            .handler = .{ .sigaction = std.os.SIG.IGN },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);
    }

    pid = std.os.fork() catch unreachable;

    if (pid < 0)
        std.os.exit(EXIT_FAILURE);
    if (pid > 0)
        std.os.exit(EXIT_SUCCESS);

    _ = std.os.linux.syscall1(std.os.linux.SYS.umask, 0);

    std.os.chdirZ("/") catch unreachable;

    _ = std.os.close(std.os.STDOUT_FILENO);
    _ = std.os.close(std.os.STDERR_FILENO);
    _ = std.os.close(std.os.STDIN_FILENO);

    has_daemonized = 1;

    if (name) |exists| {
        if (log_open == 0) {
            const LOG_PID = 0x01;
            const LOG_DAEMON = 3 << 3;

            std.c.openlog(exists, LOG_PID, LOG_DAEMON);
            log_open = 1;
        }
        var buffer: [64]u8 = undefined;
        const data = std.fmt.bufPrint(&buffer, "{d}", .{std.os.linux.getpid()}) catch unreachable;

        std.fs.cwd().writeFile("/tmp/" ++ exists ++ ".pid", data) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => syslog(.err, "failed to create pidfile ({s})", .{@errorName(err)}),
        };
    }
}
