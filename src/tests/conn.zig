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

test "state transitions and recovery" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-conn-test2", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-conn-test2/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    try std.testing.expectEqual(zkuzu.ConnState.idle, conn.getState());

    // Begin transaction -> in_transaction
    try conn.beginTransaction();
    try std.testing.expectEqual(zkuzu.ConnState.in_transaction, conn.getState());

    // Query within transaction retains transaction state
    var q = try conn.query("RETURN 1");
    defer q.deinit();
    try std.testing.expectEqual(zkuzu.ConnState.in_transaction, conn.getState());

    // Commit -> idle
    try conn.commit();
    try std.testing.expectEqual(zkuzu.ConnState.idle, conn.getState());

    // Force a failure with an invalid statement
    try std.testing.expectError(zkuzu.Error.QueryFailed, conn.query("THIS IS NOT VALID CYPHER"));
    try std.testing.expectEqual(zkuzu.ConnState.failed, conn.getState());

    // Automatic recovery on next operation
    var q2 = try conn.query("RETURN 2");
    defer q2.deinit();
    try std.testing.expectEqual(zkuzu.ConnState.idle, conn.getState());
}

const WorkerCtx = struct {
    pool: *zkuzu.Pool,
    err_count: *std.atomic.Value(u32),
};

fn worker(ctx: *WorkerCtx) void {
    // Each worker acquires, runs a simple query, releases
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var c = ctx.pool.acquire() catch {
            _ = ctx.err_count.fetchAdd(1, .monotonic);
            continue;
        };
        var qr = c.query("RETURN 1") catch {
            _ = ctx.err_count.fetchAdd(1, .monotonic);
            ctx.pool.release(c);
            continue;
        };
        qr.deinit();
        ctx.pool.release(c);
    }
}

test "pool validates and handles concurrent usage" {
    const a = std.testing.allocator;
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-conn-test3", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-conn-test3/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var pool = try zkuzu.Pool.init(a, &db, 4);
    defer pool.deinit();

    // Pre-acquire and induce a failure then release
    var c0 = try pool.acquire();
    _ = c0.query("BAD QUERY TO FAIL") catch {};
    pool.release(c0);

    // Now run concurrent workers; pool should validate and repair
    var err_count = std.atomic.Value(u32).init(0);
    var ctx = WorkerCtx{ .pool = &pool, .err_count = &err_count };
    var threads: [8]std.Thread = undefined;
    var t: usize = 0;
    while (t < threads.len) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, worker, .{&ctx});
    }
    for (threads) |th| th.join();

    // Allow some errors but expect most operations to succeed and pool to be functional
    try std.testing.expect(err_count.load(.monotonic) < 8);

    const stats = pool.getStats();
    try std.testing.expect(stats.total_connections <= 4);
}
