const std = @import("std");
const zkuzu = @import("../root.zig");
const pool_mod = @import("../pool.zig");

test "connection pool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create temp directory for test database
    if (std.fs.cwd().access("zig-cache/zkuzu-pool-test", .{})) {
        std.fs.cwd().deleteTree("zig-cache/zkuzu-pool-test") catch |err| return err;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var tmp_dir = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-pool-test", .{});
    defer tmp_dir.close();

    const db_path = try zkuzu.toCString(allocator, "zig-cache/zkuzu-pool-test/db");
    defer allocator.free(db_path);

    std.debug.print("pool test: opening database\n", .{});
    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

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
    var _cq0 = pool.query("CREATE NODE TABLE IF NOT EXISTS TestNode(id INT64, PRIMARY KEY(id))") catch |err| {
        std.debug.print("create table failed: {}\n", .{err});
        return err;
    };
    _cq0.deinit();
    std.debug.print("pool: inserting row...\n", .{});
    var _cq1 = pool.query("MERGE (:TestNode {id: 1})") catch |err| {
        std.debug.print("insert failed: {}\n", .{err});
        return err;
    };
    _cq1.deinit();

    std.debug.print("pool: querying rows...\n", .{});
    var result = pool.query("MATCH (n:TestNode) RETURN n.id") catch |err| {
        std.debug.print("select failed: {}\n", .{err});
        return err;
    };
    // keep result alive only within this scope

    if (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const id = try row.getInt(0);
        try testing.expectEqual(@as(i64, 1), id);
    }

    // Close result before invoking withConnection helper
    result.deinit();

    // withConnection helper (happy path)
    const CombinedError = zkuzu.Error;
    const fetched = pool.withConnection(CombinedError!i64, .{}, struct {
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
    }.run) catch |err| {
        std.debug.print("withConnection fetch failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqual(@as(i64, 5), fetched);

    // Saturate pool and ensure additional acquires block until release.
    const held = [_]*zkuzu.Conn{
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
        try pool.acquire(),
    };

    const WaitCtx = struct {
        pool: *pool_mod.Pool,
        success: *std.atomic.Value(bool),
        failure: *std.atomic.Value(bool),
    };

    var wait_success = std.atomic.Value(bool).init(false);
    var wait_failure = std.atomic.Value(bool).init(false);
    var wait_ctx = WaitCtx{ .pool = &pool, .success = &wait_success, .failure = &wait_failure };

    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WaitCtx) void {
            const conn = ctx.pool.acquire() catch {
                ctx.failure.store(true, .seq_cst);
                return;
            };
            ctx.pool.release(conn);
            ctx.success.store(true, .seq_cst);
        }
    }.run, .{&wait_ctx});

    // Allow waiter to block, then release one connection to unblock it.
    std.Thread.sleep(5 * std.time.ns_per_ms);
    pool.release(held[0]);

    waiter.join();
    try testing.expect(wait_success.load(.seq_cst));
    try testing.expect(!wait_failure.load(.seq_cst));

    // Release remaining held connections (skip index 0 already returned).
    var idx: usize = 1;
    while (idx < held.len) : (idx += 1) {
        pool.release(held[idx]);
    }

    const stats_final = pool.getStats();
    try testing.expectEqual(@as(usize, 5), stats_final.total_connections);
    try testing.expectEqual(@as(usize, 0), stats_final.in_use);
    try testing.expectEqual(@as(usize, 5), stats_final.available);
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
    const row1 = try qr1.next();
    try testing.expect(row1 != null);
    if (row1) |r| {
        defer r.deinit();
    }

    // Close first check result before next transaction
    qr1.deinit();

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
