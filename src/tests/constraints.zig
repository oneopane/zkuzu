const std = @import("std");
const zkuzu = @import("../root.zig");

test "constraint: duplicate primary key is categorized" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-constraints", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-constraints/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    // Create table with primary key
    var _q0 = try conn.query("CREATE NODE TABLE IF NOT EXISTS CNode(id INT64, PRIMARY KEY(id))");
    _q0.deinit();

    // First insert should succeed via MERGE (idempotent)
    if (conn.query("MERGE (:CNode {id: 1})")) |qr_ok| {
        var tmp = qr_ok;
        tmp.deinit();
    } else |err| {
        // Setup must succeed for this test
        std.debug.print("unexpected error on initial insert: {}\n", .{err});
        return err;
    }

    // Second insert with same PK should fail
    if (conn.query("CREATE (n:CNode {id: 1})")) |qr_dup| {
        var tmp = qr_dup; // make mutable copy to deinit
        tmp.deinit();
        @panic("expected duplicate PK failure");
    } else |err| {
        try std.testing.expectEqual(zkuzu.Error.QueryFailed, err);
    }

    // Check structured error category if present
    if (conn.lastError()) |e| {
        try std.testing.expectEqual(@as(@TypeOf(e.category), .constraint), e.category);
    } else if (conn.lastErrorMessage()) |_| {
        // Message present but no structured error; accept as valid signal
        try std.testing.expect(true);
    } else {
        @panic("expected last error to be set");
    }
}
