//! discord-feed: an always-on-top window showing a live, decaying feed of
//! incoming Discord messages. Messages arrive from the DiscordFeed Vencord
//! plugin over a Unix socket as newline-delimited JSON. This file owns all
//! state and policy; src/shim.cpp is the Qt view behind a small C ABI.

const std = @import("std");
const Io = std.Io;
const c = std.c;

// ---- C ABI of the Qt shim (src/shim.h) -------------------------------------

const DfStr = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn of(s: []const u8) DfStr {
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

const Action = enum(c_int) {
    ack_mode = 1,
    decay = 2,
    opacity = 3,
    on_top = 4,
    click_through = 5,
    pause = 6,
    clear = 7,
    quit = 8,
    _,
};

const DfCallbacks = extern struct {
    ctx: *anyopaque,
    tick: *const fn (*anyopaque) callconv(.c) void,
    readable: *const fn (*anyopaque) callconv(.c) void,
    entry_clicked: *const fn (*anyopaque, u64) callconv(.c) void,
    entry_dismissed: *const fn (*anyopaque, u64) callconv(.c) void,
    hover: *const fn (*anyopaque, c_int) callconv(.c) void,
    action: *const fn (*anyopaque, c_int, c_int) callconv(.c) void,
    geometry: *const fn (*anyopaque, c_int, c_int, c_int, c_int) callconv(.c) void,
};

const DfState = extern struct {
    opacity: c_int,
    on_top: c_int,
    click_through: c_int,
    ack_mode: c_int,
    decay_s: c_int,
    paused: c_int,
};

extern fn df_init(argc: c_int, argv: [*]const [*:0]const u8, cb: *const DfCallbacks) c_int;
extern fn df_set_geometry(x: c_int, y: c_int, w: c_int, h: c_int) void;
extern fn df_apply(st: *const DfState) void;
extern fn df_watch_fd(fd: c_int) void;
extern fn df_add(id: u64, author: DfStr, where: DfStr, content: DfStr, avatar: DfStr, ts_ms: i64, mention: c_int) void;
extern fn df_fade(id: u64) void;
extern fn df_set_read(id: u64) void;
extern fn df_set_status(connected: c_int, text: DfStr) void;
extern fn df_exec() c_int;
extern fn df_quit() void;

// ---- Configuration ----------------------------------------------------------

const AckMode = enum { off, on_show, on_fade };

const Config = struct {
    x: i32 = -1,
    y: i32 = -1,
    w: i32 = 380,
    h: i32 = 520,
    opacity: i32 = 85,
    on_top: bool = true,
    click_through: bool = false,
    ack_mode: AckMode = .off,
    /// Seconds an entry stays before fading; 0 keeps entries until dismissed.
    decay_s: i32 = 60,
    max_entries: u32 = 60,
    /// Message bodies longer than this are cut off with an ellipsis.
    max_chars: u32 = 400,
};

// ---- Protocol ---------------------------------------------------------------

/// Superset of every message the plugin sends; `type` selects which fields matter.
const Incoming = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    channel_id: ?[]const u8 = null,
    guild_id: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    author: []const u8 = "",
    avatar: []const u8 = "",
    where: []const u8 = "",
    content: []const u8 = "",
    mention: bool = false,
    timestamp: i64 = 0,
};

fn snowflake(s: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

// ---- App --------------------------------------------------------------------

const Entry = struct {
    id: u64,
    channel_id: []u8,
    guild_id: ?[]u8,
    message_id: []u8,
    /// Monotonic ms; null = never expires.
    expires_ms: ?i64,
    read: bool,
};

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,
    config_path: []const u8,
    socket_path: []const u8,

    fd: c.fd_t = -1,
    next_connect_ms: i64 = 0,
    rbuf: std.ArrayList(u8) = .empty,

    entries: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,

    hovering: bool = false,
    paused: bool = false,
    frozen_since: ?i64 = null,

    fn nowMs(app: *App) i64 {
        const ns = Io.Clock.awake.now(app.io).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    // -- config --

    fn loadConfig(app: *App) void {
        const data = Io.Dir.cwd().readFileAlloc(app.io, app.config_path, app.gpa, .limited(1 << 20)) catch return;
        defer app.gpa.free(data);
        const parsed = std.json.parseFromSlice(Config, app.gpa, data, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("ignoring {s}: {t}", .{ app.config_path, err });
            return;
        };
        defer parsed.deinit();
        app.cfg = parsed.value;
        app.cfg.opacity = std.math.clamp(app.cfg.opacity, 10, 100);
        app.cfg.decay_s = @max(app.cfg.decay_s, 0);
        app.cfg.max_entries = @max(app.cfg.max_entries, 1);
    }

    fn saveConfig(app: *App) void {
        const json = std.json.Stringify.valueAlloc(app.gpa, app.cfg, .{ .whitespace = .indent_2 }) catch return;
        defer app.gpa.free(json);
        if (std.fs.path.dirname(app.config_path)) |dir| Io.Dir.cwd().createDirPath(app.io, dir) catch {};
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = app.config_path, .data = json }) catch |err|
            std.log.warn("could not save {s}: {t}", .{ app.config_path, err });
    }

    fn applyState(app: *App) void {
        df_apply(&.{
            .opacity = app.cfg.opacity,
            .on_top = @intFromBool(app.cfg.on_top),
            .click_through = @intFromBool(app.cfg.click_through),
            .ack_mode = @intFromEnum(app.cfg.ack_mode),
            .decay_s = app.cfg.decay_s,
            .paused = @intFromBool(app.paused),
        });
    }

    // -- connection --

    fn tryConnect(app: *App) void {
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return;
        var addr: c.sockaddr.un = .{ .path = @splat(0) };
        if (app.socket_path.len >= addr.path.len) {
            _ = c.close(fd);
            return;
        }
        @memcpy(addr.path[0..app.socket_path.len], app.socket_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
            _ = c.close(fd);
            return;
        }
        app.fd = fd;
        app.rbuf.clearRetainingCapacity();
        df_watch_fd(fd);
        df_set_status(1, .of(""));
        std.log.info("connected to {s}", .{app.socket_path});
    }

    fn disconnect(app: *App) void {
        if (app.fd < 0) return;
        df_watch_fd(-1);
        _ = c.close(app.fd);
        app.fd = -1;
        app.next_connect_ms = app.nowMs() + 2000;
        df_set_status(0, .of("waiting for Vesktop"));
        std.log.info("disconnected", .{});
    }

    fn send(app: *App, value: anytype) void {
        if (app.fd < 0) return;
        var line = std.json.Stringify.valueAlloc(app.gpa, value, .{}) catch return;
        defer app.gpa.free(line);
        line = app.gpa.realloc(line, line.len + 1) catch return;
        line[line.len - 1] = '\n';
        // Lines are tiny, so a full socket buffer only happens if the plugin is stuck; drop then.
        const n = c.send(app.fd, line.ptr, line.len, c.MSG.DONTWAIT | c.MSG.NOSIGNAL);
        if (n < 0 and c.errno(n) != .AGAIN) app.disconnect();
    }

    fn onReadable(app: *App) void {
        var buf: [16 * 1024]u8 = undefined;
        while (app.fd >= 0) {
            const n = c.recv(app.fd, &buf, buf.len, c.MSG.DONTWAIT);
            if (n == 0) return app.disconnect();
            if (n < 0) {
                switch (c.errno(n)) {
                    .AGAIN, .INTR => break,
                    else => return app.disconnect(),
                }
            }
            app.rbuf.appendSlice(app.gpa, buf[0..@intCast(n)]) catch return app.disconnect();
        }
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, app.rbuf.items, start, '\n')) |nl| {
            app.handleLine(app.rbuf.items[start..nl]);
            start = nl + 1;
        }
        app.rbuf.replaceRangeAssumeCapacity(0, start, &.{});
    }

    fn handleLine(app: *App, line: []const u8) void {
        if (std.mem.trim(u8, line, " \r\t").len == 0) return;
        const parsed = std.json.parseFromSlice(Incoming, app.gpa, line, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("bad line from plugin: {t}", .{err});
            return;
        };
        defer parsed.deinit();
        const m = parsed.value;
        if (std.mem.eql(u8, m.type, "message")) {
            app.addMessage(m) catch |err| std.log.warn("dropped message: {t}", .{err});
        } else if (std.mem.eql(u8, m.type, "read")) {
            if (m.channel_id != null and m.message_id != null) app.markReadUpTo(m.channel_id.?, snowflake(m.message_id.?));
        } else if (std.mem.eql(u8, m.type, "delete")) {
            if (m.id) |mid| if (app.findByMessage(mid)) |i| app.removeAt(i, .silent);
        }
    }

    // -- entries --

    fn addMessage(app: *App, m: Incoming) !void {
        const channel_id = m.channel_id orelse return error.MissingChannel;
        const message_id = m.id orelse return error.MissingId;

        const ch = try app.gpa.dupe(u8, channel_id);
        errdefer app.gpa.free(ch);
        const msg = try app.gpa.dupe(u8, message_id);
        errdefer app.gpa.free(msg);
        const guild = if (m.guild_id) |g| try app.gpa.dupe(u8, g) else null;
        errdefer if (guild) |g| app.gpa.free(g);

        const id = app.next_id;
        app.next_id += 1;
        const now = app.frozen_since orelse app.nowMs();
        try app.entries.append(app.gpa, .{
            .id = id,
            .channel_id = ch,
            .guild_id = guild,
            .message_id = msg,
            .expires_ms = if (app.cfg.decay_s > 0) now + @as(i64, app.cfg.decay_s) * 1000 else null,
            .read = false,
        });

        df_add(id, .of(m.author), .of(m.where), .of(truncate(m.content, app.cfg.max_chars)), .of(m.avatar), m.timestamp, @intFromBool(m.mention));

        if (app.cfg.ack_mode == .on_show) app.ack(&app.entries.items[app.entries.items.len - 1]);
        while (app.entries.items.len > app.cfg.max_entries) app.removeAt(0, .expired);
    }

    /// Cuts `s` to at most `max` bytes on a UTF-8 boundary, marking the cut with "…".
    fn truncate(s: []const u8, max: u32) []const u8 {
        if (s.len <= max) return s;
        var end: usize = max;
        while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
        // The shim copies the string immediately, so a static buffer is fine.
        const S = struct {
            var buf: [4096]u8 = undefined;
        };
        const n = @min(end, S.buf.len - 3);
        @memcpy(S.buf[0..n], s[0..n]);
        @memcpy(S.buf[n .. n + 3], "…");
        return S.buf[0 .. n + 3];
    }

    fn ack(app: *App, e: *Entry) void {
        if (e.read) return;
        e.read = true;
        app.send(.{ .type = "ack", .channel_id = e.channel_id, .message_id = e.message_id });
        df_set_read(e.id);
    }

    fn markReadUpTo(app: *App, channel_id: []const u8, upto: u64) void {
        for (app.entries.items) |*e| {
            if (!e.read and std.mem.eql(u8, e.channel_id, channel_id) and snowflake(e.message_id) <= upto) {
                e.read = true;
                df_set_read(e.id);
            }
        }
    }

    fn findByMessage(app: *App, message_id: []const u8) ?usize {
        for (app.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.message_id, message_id)) return i;
        return null;
    }

    fn findById(app: *App, id: u64) ?usize {
        for (app.entries.items, 0..) |e, i| if (e.id == id) return i;
        return null;
    }

    const Removal = enum {
        /// Timed out or pushed out by newer entries: acks in "when it fades" mode.
        expired,
        /// The user dismissed it: counts as seen in either ack mode.
        dismissed,
        /// Deleted on Discord's side: no ack.
        silent,
    };

    fn removeAt(app: *App, i: usize, why: Removal) void {
        const e = &app.entries.items[i];
        switch (why) {
            .expired => if (app.cfg.ack_mode == .on_fade) app.ack(e),
            .dismissed => if (app.cfg.ack_mode != .off) app.ack(e),
            .silent => {},
        }
        df_fade(e.id);
        app.gpa.free(e.channel_id);
        app.gpa.free(e.message_id);
        if (e.guild_id) |g| app.gpa.free(g);
        _ = app.entries.orderedRemove(i);
    }

    /// Fading stops while the pointer is over the window or when paused from the menu.
    fn updateFreeze(app: *App) void {
        const want = app.hovering or app.paused;
        if (want and app.frozen_since == null) {
            app.frozen_since = app.nowMs();
        } else if (!want and app.frozen_since != null) {
            const held = app.nowMs() - app.frozen_since.?;
            for (app.entries.items) |*e| {
                if (e.expires_ms) |*t| t.* += held;
            }
            app.frozen_since = null;
        }
    }

    fn onTick(app: *App) void {
        const now = app.nowMs();
        if (app.fd < 0 and now >= app.next_connect_ms) {
            app.tryConnect();
            if (app.fd < 0) app.next_connect_ms = now + 2000;
        }
        if (app.frozen_since != null) return;
        var i: usize = 0;
        while (i < app.entries.items.len) {
            if (app.entries.items[i].expires_ms) |t| if (t <= now) {
                app.removeAt(i, .expired);
                continue;
            };
            i += 1;
        }
    }

    fn onAction(app: *App, action: Action, value: c_int) void {
        switch (action) {
            .ack_mode => app.cfg.ack_mode = std.enums.fromInt(AckMode, value) orelse .off,
            .decay => {
                app.cfg.decay_s = @max(value, 0);
                // Re-time what's on screen so the new setting takes effect right away.
                const now = app.frozen_since orelse app.nowMs();
                for (app.entries.items) |*e|
                    e.expires_ms = if (value > 0) now + @as(i64, value) * 1000 else null;
            },
            .opacity => app.cfg.opacity = std.math.clamp(value, 10, 100),
            .on_top => app.cfg.on_top = value != 0,
            .click_through => app.cfg.click_through = value != 0,
            .pause => {
                app.paused = value != 0;
                app.updateFreeze();
            },
            .clear => while (app.entries.items.len > 0) app.removeAt(0, .dismissed),
            .quit => return df_quit(),
            _ => return,
        }
        app.saveConfig();
        app.applyState();
    }

    fn onClicked(app: *App, id: u64) void {
        const i = app.findById(id) orelse return;
        const e = &app.entries.items[i];
        app.send(.{ .type = "open", .channel_id = e.channel_id, .guild_id = e.guild_id, .message_id = e.message_id });
        // Opening the channel in Discord marks it read there.
        e.read = true;
        df_set_read(id);
    }
};

// ---- Callback trampolines ---------------------------------------------------

fn appOf(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn cbTick(ctx: *anyopaque) callconv(.c) void {
    appOf(ctx).onTick();
}
fn cbReadable(ctx: *anyopaque) callconv(.c) void {
    appOf(ctx).onReadable();
}
fn cbClicked(ctx: *anyopaque, id: u64) callconv(.c) void {
    appOf(ctx).onClicked(id);
}
fn cbDismissed(ctx: *anyopaque, id: u64) callconv(.c) void {
    const app = appOf(ctx);
    if (app.findById(id)) |i| app.removeAt(i, .dismissed);
}
fn cbHover(ctx: *anyopaque, inside: c_int) callconv(.c) void {
    const app = appOf(ctx);
    app.hovering = inside != 0;
    app.updateFreeze();
}
fn cbAction(ctx: *anyopaque, action: c_int, value: c_int) callconv(.c) void {
    appOf(ctx).onAction(@enumFromInt(action), value);
}
fn cbGeometry(ctx: *anyopaque, x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
    const app = appOf(ctx);
    app.cfg.x = x;
    app.cfg.y = y;
    app.cfg.w = w;
    app.cfg.h = h;
    app.saveConfig();
}

// ---- main -------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    const config_path = if (env.get("XDG_CONFIG_HOME")) |x|
        try std.fs.path.join(arena, &.{ x, "discord-feed", "config.json" })
    else if (env.get("HOME")) |h|
        try std.fs.path.join(arena, &.{ h, ".config", "discord-feed", "config.json" })
    else
        return error.NoHomeDirectory;

    // Must match socketPath() in plugin/discordFeed/native.ts.
    const socket_path = if (env.get("DISCORD_FEED_SOCKET")) |s|
        s
    else
        try std.fmt.allocPrint(arena, "{s}/discord-feed-{d}.sock", .{ env.get("XDG_RUNTIME_DIR") orelse "/tmp", c.getuid() });

    var app: App = .{
        .gpa = gpa,
        .io = init.io,
        .cfg = .{},
        .config_path = config_path,
        .socket_path = socket_path,
    };
    app.loadConfig();

    const callbacks: DfCallbacks = .{
        .ctx = &app,
        .tick = cbTick,
        .readable = cbReadable,
        .entry_clicked = cbClicked,
        .entry_dismissed = cbDismissed,
        .hover = cbHover,
        .action = cbAction,
        .geometry = cbGeometry,
    };
    const argv = [_][*:0]const u8{"discord-feed"};
    _ = df_init(1, &argv, &callbacks);
    df_set_geometry(app.cfg.x, app.cfg.y, app.cfg.w, app.cfg.h);
    app.applyState();
    app.onTick(); // connect right away instead of after the first 200 ms

    const rc = df_exec();
    app.disconnect();
    if (rc != 0) std.process.exit(@intCast(rc));
}
