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

test "arena-backed strings lifetime and leak sanity" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-qr-arena", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-qr-arena/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    // Create and populate
    var _q0 = try conn.query("CREATE NODE TABLE IF NOT EXISTS S(id INT64, s STRING, PRIMARY KEY(id))");
    _q0.deinit();
    var _q1 = try conn.query("MERGE (:S {id: 1, s: 'hello'})");
    _q1.deinit();
    var _q2 = try conn.query("MERGE (:S {id: 2, s: 'world'})");
    _q2.deinit();

    var qr = try conn.query("MATCH (n:S) RETURN n.s AS s ORDER BY n.id");
    defer qr.deinit();

    var first: ?[]const u8 = null;

    // Read first row and keep string after row is deinitialized
    if (try qr.next()) |row_ptr| {
        const row = row_ptr;
        const s = try row.getString(0);
        // Keep pointer beyond row lifetime
        first = s;
        row.deinit();
    }

    // Ensure we can still access the first string after row is gone
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("hello", first.?);

    // Iterate remaining rows and reset iterator to exercise arena reuse
    if (try qr.next()) |row_ptr2| {
        const row2 = row_ptr2;
        _ = try row2.getString(0);
        row2.deinit();
    }
    qr.reset();

    // Iterate again to ensure no crashes and arena allocations succeed repeatedly
    while (try qr.next()) |row_ptr3| {
        const row3 = row_ptr3;
        _ = try row3.getString(0);
        row3.deinit();
    }
}
