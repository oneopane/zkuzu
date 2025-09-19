const std = @import("std");
const zkuzu = @import("../root.zig");
const tutil = @import("util.zig");
const Transaction = @import("../pool.zig").Transaction;

fn insertPerson(conn: *zkuzu.Conn, name: []const u8, age: i64) !void {
    var ps = try conn.prepare("MERGE (:Person {name: $name, age: $age})");
    defer ps.deinit();
    try ps.bindString("name", name);
    try ps.bindInt("age", age);
    var qr = try ps.execute();
    qr.deinit();
}

fn countPersons(conn: *zkuzu.Conn) !u64 {
    var qr = try conn.query("MATCH (p:Person) RETURN count(p)");
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        const c = try row.get(u64, 0);
        return c;
    }
    return 0;
}

test "integration: end-to-end workflow with pool and prepared statements" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-int-e2e", "db");
    defer fx.deinit();

    // Schema
    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
    try fx.conn.exec("CREATE REL TABLE IF NOT EXISTS Knows(FROM Person TO Person)");

    // Initial inserts (prepared)
    try insertPerson(&fx.conn, "Alice", 30);
    try insertPerson(&fx.conn, "Bob", 25);

    // Verify simple query
    var qr = try fx.conn.query("MATCH (p:Person) RETURN p.name ORDER BY p.name");
    defer qr.deinit();
    var seen: usize = 0;
    while (try qr.next()) |row| {
        defer row.deinit();
        _ = try row.get([]const u8, 0);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);

    // Use pool to run concurrent writes
    var pool = try zkuzu.Pool.init(a, &fx.db, 4);
    defer pool.deinit();

    const WorkerCtx = struct { pool: *zkuzu.Pool, idx: usize };
    fn worker(ctx: *WorkerCtx) !void {
        // Each worker inserts one unique Person in a transaction
        _ = try ctx.pool.withTransaction(!void, ctx.idx, struct {
            fn cb(tx: *Transaction, i: usize) !void {
                var ps = try tx.prepare("MERGE (:Person {name: $name, age: $age})");
                defer ps.deinit();
                var name_buf: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "Worker-{d}", .{i});
                try ps.bindString("name", name);
                try ps.bindInt("age", @as(i64, @intCast(20 + @as(i64, @intCast(i)))));
                var qr2 = try ps.execute();
                qr2.deinit();
            }
        }.cb);
    }

    var threads: [8]std.Thread = undefined;
    var ctxs: [8]WorkerCtx = undefined;
    var i: usize = 0;
    while (i < threads.len) : (i += 1) {
        ctxs[i] = .{ .pool = &pool, .idx = i };
        threads[i] = try std.Thread.spawn(.{}, worker, .{&ctxs[i]});
    }
    for (threads) |th| th.join();

    // Count after concurrent inserts
    const cnt = try countPersons(&fx.conn);
    try std.testing.expect(cnt >= 2 + 8);
}

test "integration: large dataset and timing" {
    const a = std.testing.allocator;
    var fx = try tutil.DbFixture.init(a, "zig-cache/zkuzu-int-large", "db");
    defer fx.deinit();

    try fx.conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");

    var t_ins = try tutil.Timer.start();
    try fx.conn.beginTransaction();
    var j: usize = 0;
    while (j < 1000) : (j += 1) {
        var ps = try fx.conn.prepare("MERGE (:Person {name: $name, age: $age})");
        defer ps.deinit();
        var buf: [32]u8 = undefined;
        const nm = try std.fmt.bufPrint(&buf, "U-{d}", .{j});
        try ps.bindString("name", nm);
        try ps.bindInt("age", @as(i64, @intCast(18 + (j % 60))));
        var qr = try ps.execute();
        qr.deinit();
    }
    try fx.conn.commit();
    const ins_ms = t_ins.elapsedMs();
    std.debug.print("insert 1000 rows: {} ms\n", .{ins_ms});

    var t_q = try tutil.Timer.start();
    var qr = try fx.conn.query("MATCH (p:Person) RETURN count(p)");
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        _ = try row.get(u64, 0);
    }
    std.debug.print("count query: {} ms\n", .{t_q.elapsedMs()});
}
