const std = @import("std");
const zkuzu = @import("../root.zig");
const tutil = @import("util.zig");
const Transaction = @import("../pool.zig").Transaction;

test "tx: nested begin fails and recovery works" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-tx-nested", "db");
    defer fx.deinit();

    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS Item(id INT64, PRIMARY KEY(id))");

    try fx.conn.beginTransaction();
    // nested begin should fail and mark failed
    const nested = fx.conn.beginTransaction();
    try std.testing.expectError(zkuzu.Error.TransactionFailed, nested);
    try std.testing.expectEqual(zkuzu.ConnState.failed, fx.conn.getState());

    // Recover and ensure usable
    try fx.conn.recover();
    try std.testing.expectEqual(zkuzu.ConnState.idle, fx.conn.getState());
    var qr = try fx.conn.query("RETURN 2");
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 2), try row.get(i64, 0));
    }
}

test "tx: rollback discards changes" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-tx-rollback", "db");
    defer fx.deinit();

    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS User(name STRING, PRIMARY KEY(name))");

    try fx.conn.beginTransaction();
    try fx.conn.exec("MERGE (:User {name:'X'})");
    try fx.conn.rollback();

    var qr = try fx.conn.query("MATCH (u:User {name:'X'}) RETURN u");
    defer qr.deinit();
    try std.testing.expectEqual(@as(?*zkuzu.Row, null), try qr.next());
}

test "tx: concurrent transactions via pool (no deadlock)" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-tx-concurrent", "db");
    defer fx.deinit();
    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS Account(id INT64, PRIMARY KEY(id))");

    var pool = try zkuzu.Pool.init(a, &fx.db, 4);
    defer pool.deinit();

    const WorkerCtx = struct { pool: *zkuzu.Pool, id: usize };
    const Worker = struct {
        const TxResult = (zkuzu.Error || error{PoolExhausted})!void;

        fn txCb(tx: *Transaction, i: usize) TxResult {
            var ps = try tx.prepare("MERGE (:Account {id: $id})");
            defer ps.deinit();
            try ps.bindInt("id", @as(i64, @intCast(i)));
            var qr = try ps.execute();
            qr.deinit();
            return;
        }

        fn run(ctx: *WorkerCtx) !void {
            try ctx.pool.withTransaction(TxResult, ctx.id, txCb);
        }
    };

    var threads: [6]std.Thread = undefined;
    var ctxs: [6]WorkerCtx = undefined;
    var i: usize = 0;
    while (i < threads.len) : (i += 1) {
        ctxs[i] = .{ .pool = &pool, .id = i };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&ctxs[i]});
    }
    for (threads) |th| th.join();

    var cnt_q = try fx.conn.query("MATCH (a:Account) RETURN count(a)");
    defer cnt_q.deinit();
    if (try cnt_q.next()) |row| {
        defer row.deinit();
        const c = try row.get(u64, 0);
        try std.testing.expect(c >= threads.len);
    } else {
        try std.testing.expect(false);
    }
}

test "tx: single-connection pool avoids deadlock and reports exhaustion" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-tx-exhaust", "db");
    defer fx.deinit();
    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS T(id INT64, PRIMARY KEY(id))");

    var pool = try zkuzu.Pool.init(a, &fx.db, 1);
    defer pool.deinit();

    // Hold a long transaction using the only connection
    var held = try pool.acquire();
    try held.beginTransaction();

    // Concurrent attempt should return PoolExhausted, not deadlock
    var err_count: usize = 0;
    var th = try std.Thread.spawn(.{}, struct {
        const ExhaustResult = (zkuzu.Error || error{PoolExhausted})!void;

        fn run(p: *zkuzu.Pool, ec: *usize) void {
            _ = p.withTransaction(ExhaustResult, {}, struct {
                fn cb(tx: *Transaction, _: void) ExhaustResult {
                    _ = tx;
                    return;
                }
            }.cb) catch {
                ec.* += 1;
            };
        }
    }.run, .{ &pool, &err_count });

    th.join();
    try std.testing.expect(err_count >= 1);

    // Cleanup held tx to release the connection
    try held.rollback();
    pool.release(held);
}
