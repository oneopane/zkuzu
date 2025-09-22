const std = @import("std");
const zkuzu = @import("../root.zig");
const pool_mod = @import("../pool.zig");

test "pool: cleanupIdle removes idle connections" {
    const a = std.testing.allocator;
    const base = "zig-cache/zkuzu-pool-lifecycle-cleanup";
    if (std.fs.cwd().access(base, .{})) {
        std.fs.cwd().deleteTree(base) catch |err| return err;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    _ = try std.fs.cwd().makeOpenPath(base, .{});
    const db_path = try zkuzu.toCString(a, base ++ "/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var pool = try pool_mod.Pool.init(a, &db, 3);
    defer pool.deinit();

    // Create three pooled connections by holding them before release
    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    const c3 = try pool.acquire();
    pool.release(c1);
    pool.release(c2);
    pool.release(c3);

    const before = pool.getStats();
    try std.testing.expectEqual(@as(usize, 3), before.total_connections);

    // Wait so they become old enough for cleanup (busy-wait to avoid platform sleep differences)
    const start_ms = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start_ms < 2100) {
        // spin
    }
    try pool.cleanupIdle(1); // remove older than 1s

    const after = pool.getStats();
    try std.testing.expect(after.total_connections < before.total_connections);
}

test "pool: healthCheckAll recovers failed connections" {
    const a = std.testing.allocator;
    const base = "zig-cache/zkuzu-pool-lifecycle-health";
    if (std.fs.cwd().access(base, .{})) {
        std.fs.cwd().deleteTree(base) catch |err| return err;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    _ = try std.fs.cwd().makeOpenPath(base, .{});
    const db_path = try zkuzu.toCString(a, base ++ "/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var pool = try pool_mod.Pool.init(a, &db, 2);
    defer pool.deinit();

    // Acquire and intentionally fail the connection with a bad query
    const conn = try pool.acquire();
    _ = conn.query("THIS IS NOT CYPHER") catch |e| {
        // Swallow the error; it's intentional
        switch (e) {
            else => {},
        }
    };
    pool.release(conn);

    // Run health check across all connections; it should validate/recover.
    try pool.healthCheckAll();

    // On next acquire, a simple query should succeed
    const conn2 = try pool.acquire();
    var qr = try conn2.query("RETURN 1");
    defer qr.deinit();
    _ = try qr.next();
    pool.release(conn2);
}
