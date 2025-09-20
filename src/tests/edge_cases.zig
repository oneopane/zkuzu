const std = @import("std");
const zkuzu = @import("../root.zig");
const tutil = @import("util.zig");

test "edge: null handling and empty result sets" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-edge-null", "db");
    defer fx.deinit();

    // RETURN NULL
    var qr = try fx.conn.query("RETURN NULL");
    if (try qr.next()) |row| {
        defer row.deinit();
        // Optional should read null
        const v_opt = try row.get(?i64, 0);
        try std.testing.expect(v_opt == null);
        // Non-optional should error
        try std.testing.expectError(zkuzu.Error.InvalidArgument, row.get(i64, 0));
    } else {
        try std.testing.expect(false); // should have a single row
    }

    // Close before executing another query
    qr.deinit();

    // Empty result: use a query that returns no rows without relying on schema
    var none = try fx.conn.query("RETURN 1 LIMIT 0");
    defer none.deinit();
    try std.testing.expectEqual(@as(?*zkuzu.Row, null), try none.next());
}

test "edge: maximum parameter binding (stress)" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-edge-params", "db");
    defer fx.deinit();

    // Build a RETURN $p0 + $p1 + ... expression
    const N: usize = 32; // conservative but meaningful coverage
    var qbuf = std.ArrayList(u8){};
    defer qbuf.deinit(a);
    var writer = qbuf.writer(a);
    try writer.print("RETURN ", .{});
    var expected: i64 = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        if (i != 0) try writer.print(" + ", .{});
        try writer.print("$p{d}", .{i});
        expected += @as(i64, @intCast(i));
    }
    const q = try qbuf.toOwnedSlice(a);
    defer a.free(q);

    var ps = try fx.conn.prepare(q);
    defer ps.deinit();
    i = 0;
    while (i < N) : (i += 1) {
        var name_buf: [8]u8 = undefined;
        const pname = try std.fmt.bufPrint(&name_buf, "p{d}", .{i});
        try ps.bindInt(pname, @as(i64, @intCast(i)));
    }
    var qr = try ps.execute();
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        const got = try row.get(i64, 0);
        try std.testing.expectEqual(expected, got);
    } else {
        try std.testing.expect(false);
    }
}

test "edge: connection failure and recovery" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-edge-recover", "db");
    defer fx.deinit();

    // Force an operation error that marks connection as failed
    // commit while not in a transaction -> error
    try std.testing.expectError(zkuzu.Error.TransactionFailed, fx.conn.commit());

    // Validate should attempt recovery and bring it back to usable
    _ = fx.conn.validate() catch {};

    // Query should work after recovery
    var qr = try fx.conn.query("RETURN 1");
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 1), try row.get(i64, 0));
    } else {
        try std.testing.expect(false);
    }
}
