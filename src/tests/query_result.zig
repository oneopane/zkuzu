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

test "type-safe getters: scalars, nullables, lists, and mismatches" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-qr-typesafe", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-qr-typesafe/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    var qr = try conn.query("RETURN 1 AS i, 2.5 AS f, TRUE AS b, 'hello' AS s, CAST(NULL AS INT64) AS ni, [1,2,3] AS l, 127 AS small, 128 AS big");
    defer qr.deinit();

    const row_opt = try qr.next();
    try std.testing.expect(row_opt != null);
    const row = row_opt.?;

    // Scalars
    try std.testing.expectEqual(@as(i64, 1), try row.get(i64, 0));
    try std.testing.expectEqual(@as(f64, 2.5), try row.get(f64, 1));
    try std.testing.expectEqual(true, try row.get(bool, 2));
    try std.testing.expectEqualStrings("hello", try row.get([]const u8, 3));

    // Nullables
    try std.testing.expectEqual(@as(?i64, null), try row.get(?i64, 4));
    try std.testing.expectError(zkuzu.Error.InvalidArgument, row.get(i64, 4));

    // Lists
    const l = try row.get([]const i64, 5);
    try std.testing.expectEqual(@as(usize, 3), l.len);
    try std.testing.expectEqual(@as(i64, 1), l[0]);
    try std.testing.expectEqual(@as(i64, 2), l[1]);
    try std.testing.expectEqual(@as(i64, 3), l[2]);

    // Conversions with safety checks
    try std.testing.expectEqual(@as(i8, 127), try row.get(i8, 6));
    try std.testing.expectError(zkuzu.Error.ConversionError, row.get(i8, 7));

    // Mismatch detection
    try std.testing.expectError(zkuzu.Error.TypeMismatch, row.get(i64, 3)); // 's' is string

    row.deinit();
}

test "result guard clears on deinit" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-qr-guard", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-qr-guard/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    var qr = try conn.query("RETURN 1");
    // Overlapping query should fail while result is active
    try std.testing.expectError(zkuzu.Error.Busy, conn.query("RETURN 2"));
    qr.deinit();

    // After deinit, queries should work again
    var ok = try conn.query("RETURN 3");
    ok.deinit();
}

test "getDouble alias and timestamp tz getter" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-qr-double-tstz", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-qr-double-tstz/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    // Verify getDouble mirrors getFloat
    {
        var qr = try conn.query("RETURN 2.5 AS d");
        defer qr.deinit();
        const row_opt = try qr.next();
        try std.testing.expect(row_opt != null);
        const row = row_opt.?;
        defer row.deinit();
        const f = try row.getFloat(0);
        const d = try row.getDouble(0);
        try std.testing.expectEqual(@as(f64, 2.5), f);
        try std.testing.expectEqual(f, d);
    }

    // Verify timezone-aware timestamp round-trips via prepared bind + row getter
    {
        var ps = try conn.prepare("RETURN $t AS t");
        defer ps.deinit();

        var tmv: zkuzu.c.tm = std.mem.zeroes(zkuzu.c.tm);
        tmv.tm_year = 124; // 2024
        tmv.tm_mon = 0; // Jan
        tmv.tm_mday = 2;
        tmv.tm_hour = 3;
        tmv.tm_min = 4;
        tmv.tm_sec = 5;
        var tz: zkuzu.c.kuzu_timestamp_tz_t = undefined;
        try zkuzu.checkState(zkuzu.c.kuzu_timestamp_tz_from_tm(tmv, &tz));

        try ps.bindTimestampTz("t", tz);
        var qr2 = try ps.execute();
        defer qr2.deinit();
        const row_opt2 = try qr2.next();
        try std.testing.expect(row_opt2 != null);
        const row2 = row_opt2.?;
        defer row2.deinit();
        const tz_out = try row2.getTimestampTz(0);
        try std.testing.expectEqual(tz.value, tz_out.value);
    }
}
