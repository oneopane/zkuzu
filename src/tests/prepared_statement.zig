const std = @import("std");
const zkuzu = @import("../root.zig");

test "prepared statement minimal" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-ps-mini", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-ps-mini/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    var ps = try conn.prepare("RETURN $x AS x");
    defer ps.deinit();
    try ps.bindInt("x", 7);
    var qr = try ps.execute();
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 7), try row.getIntByName("x"));
    } else {
        return error.UnexpectedEmpty;
    }
}

