const std = @import("std");
const zkuzu = @import("../root.zig");

test "connection basics and config" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-conn-test", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-conn-test/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    try conn.setTimeout(1_000);
    try conn.setMaxThreads(1);
    _ = try conn.getMaxThreads();
}

