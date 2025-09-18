const std = @import("std");
const zkuzu = @import("../root.zig");

test "query result metadata" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-qr-meta", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-qr-meta/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    var qr = try conn.query("RETURN 1 AS one, 'x' AS s");
    defer qr.deinit();

    try std.testing.expectEqual(@as(u64, 2), qr.getColumnCount());
    const name0 = try qr.getColumnName(0);
    const name1 = try qr.getColumnName(1);
    try std.testing.expect(name0.len > 0 and name1.len > 0);
    const idx_s = (try qr.getColumnIndex("s")) orelse return error.Missing;
    try std.testing.expectEqual(@as(u64, 1), idx_s);
    const t1 = try qr.getColumnDataType(1);
    try std.testing.expectEqual(zkuzu.ValueType.String, t1);
}

