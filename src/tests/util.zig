const std = @import("std");
const zkuzu = @import("../root.zig");

pub const Timer = struct {
    timer: std.time.Timer,

    pub fn start() !Timer {
        return .{ .timer = try std.time.Timer.start() };
    }

    pub fn elapsedMs(self: *Timer) u64 {
        return @intCast(self.timer.read() / std.time.ns_per_ms);
    }
};

pub const DbFixture = struct {
    allocator: std.mem.Allocator,
    db: zkuzu.Database,
    conn: zkuzu.Conn,
    z_path: [*:0]u8,

    pub fn init(a: std.mem.Allocator, dir: []const u8, name: []const u8) !DbFixture {
        _ = try std.fs.cwd().makeOpenPath(dir, .{});
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
        defer a.free(full);
        const z = try zkuzu.toCString(a, full);
        errdefer a.free(z);

        var db = try zkuzu.open(z, null);
        errdefer db.deinit();
        var conn = try db.connection();
        errdefer conn.deinit();

        return .{ .allocator = a, .db = db, .conn = conn, .z_path = z };
    }

    pub fn deinit(self: *DbFixture) void {
        self.conn.deinit();
        self.db.deinit();
        self.allocator.free(self.z_path);
    }
};

pub fn bench(label: []const u8, f: anytype) !u64 {
    var t = try Timer.start();
    try f();
    const ms = t.elapsedMs();
    std.debug.print("bench {s}: {} ms\n", .{ label, ms });
    return ms;
}

