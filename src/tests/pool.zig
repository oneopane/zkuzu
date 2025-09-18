const std = @import("std");
const zkuzu = @import("../root.zig");
const pool_mod = @import("../pool.zig");

test "connection pool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create temp directory for test database
    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-pool-test", .{});
    defer tmp_dir.close();

    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-pool-test/db");
    defer allocator.free(db_path);

    // Open database
    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    // Create pool
    var pool = try pool_mod.Pool.init(allocator, &db, 5);
    defer pool.deinit();

    // Test acquiring connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    const stats1 = pool.getStats();
    try testing.expectEqual(@as(usize, 2), stats1.total_connections);
    try testing.expectEqual(@as(usize, 2), stats1.in_use);

    // Release connections
    pool.release(conn1);
    pool.release(conn2);

    const stats2 = pool.getStats();
    try testing.expectEqual(@as(usize, 2), stats2.total_connections);
    try testing.expectEqual(@as(usize, 0), stats2.in_use);
    try testing.expectEqual(@as(usize, 2), stats2.available);

    // Test query through pool
    std.debug.print("pool: creating TestNode...\n", .{});
    var _cq0 = try pool.query("CREATE NODE TABLE IF NOT EXISTS TestNode(id INT64, PRIMARY KEY(id))");
    _cq0.deinit();
    std.debug.print("pool: inserting row...\n", .{});
    var _cq1 = try pool.query("MERGE (:TestNode {id: 1})");
    _cq1.deinit();

    std.debug.print("pool: querying rows...\n", .{});
    var result = try pool.query("MATCH (n:TestNode) RETURN n.id");
    defer result.deinit();

    if (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const id = try row.getInt(0);
        try testing.expectEqual(@as(i64, 1), id);
    }

    // withConnection helper (happy path)
    const CombinedError = zkuzu.Error || error{PoolExhausted};
    const fetched = try pool.withConnection(CombinedError!i64, .{}, struct {
        fn run(conn: *zkuzu.Conn, _: @TypeOf(.{})) CombinedError!i64 {
            var qr_local = try conn.query("RETURN 5");
            defer qr_local.deinit();
            if (try qr_local.next()) |row_ptr| {
                const row = row_ptr;
                defer row.deinit();
                return try row.getInt(0);
            }
            return error.QueryFailed;
        }
    }.run);
    try testing.expectEqual(@as(i64, 5), fetched);

    // Exhaust pool to ensure helper propagates PoolExhausted
    const acquired = [_]zkuzu.Conn{
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
    };
    const exhausted = pool.withConnection(CombinedError!void, .{}, struct {
        fn run(_: *zkuzu.Conn, _: @TypeOf(.{})) CombinedError!void {
            return;
        }
    }.run);
    try testing.expectError(error.PoolExhausted, exhausted);
    for (acquired) |conn_handle| {
        pool.release(conn_handle);
    }
}

test "pool.withTransaction commit and rollback" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Prepare DB
    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-pool-tx-test", .{});
    defer tmp_dir.close();
    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-pool-tx-test/db");
    defer allocator.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var pool = try pool_mod.Pool.init(allocator, &db, 2);
    defer pool.deinit();

    // Create table outside tx
    var _q0 = try pool.query("CREATE NODE TABLE IF NOT EXISTS TxNode(id INT64, PRIMARY KEY(id))");
    _q0.deinit();

    // Happy path: insert within tx and commit
    const Combined = zkuzu.Error || error{PoolExhausted};
    _ = try pool.withTransaction(Combined!void, .{}, struct {
        fn run(tx: *pool_mod.Transaction, _: @TypeOf(.{})) Combined!void {
            try tx.exec("MERGE (:TxNode {id: 42})");
            return;
        }
    }.run);

    // Verify committed
    var qr1 = try pool.query("MATCH (n:TxNode {id: 42}) RETURN n.id");
    defer qr1.deinit();
    const row1 = try qr1.next();
    try testing.expect(row1 != null);
    if (row1) |r| {
        defer r.deinit();
    }

    // Error path: insert then return error to trigger rollback
    const Combined2 = zkuzu.Error || error{ PoolExhausted, Intentional };
    const res = pool.withTransaction(Combined2!void, .{}, struct {
        fn run(tx: *pool_mod.Transaction, _: @TypeOf(.{})) Combined2!void {
            try tx.exec("MERGE (:TxNode {id: 99})");
            return error.Intentional;
        }
    }.run);
    try testing.expectError(error.Intentional, res);

    // Verify rolled back
    var qr2 = try pool.query("MATCH (n:TxNode {id: 99}) RETURN n.id");
    defer qr2.deinit();
    try testing.expectEqual(@as(?*zkuzu.Row, null), try qr2.next());
}

