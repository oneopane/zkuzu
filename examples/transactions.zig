const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-example-tx", .{});
    var db = try zkuzu.open("zig-cache/zkuzu-example-tx/db", null);
    defer db.deinit();

    var conn = try db.connection();
    defer conn.deinit();

    // Create schema
    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Account(id INT64, balance DOUBLE, PRIMARY KEY(id))");
    try conn.exec("MERGE (:Account {id:1, balance:100.0})");
    try conn.exec("MERGE (:Account {id:2, balance:50.0})");

    // Manual transaction with safe rollback on error
    try conn.beginTransaction();
    var need_rollback = true;
    defer if (need_rollback) conn.rollback() catch {};

    // Transfer 20 from id=1 to id=2
    try conn.exec("MATCH (a:Account {id:1}) SET a.balance = a.balance - 20");
    try conn.exec("MATCH (a:Account {id:2}) SET a.balance = a.balance + 20");

    // Commit
    try conn.commit();
    need_rollback = false;

    // Verify balances
    var qr = try conn.query("MATCH (a:Account) RETURN a.id AS id, a.balance AS bal ORDER BY id");
    defer qr.deinit();
    while (try qr.next()) |row| : (row.deinit()) {
        const id = try row.getIntByName("id");
        const bal = try row.getFloat(1);
        std.debug.print("Account {d} -> {d:.2}\n", .{ id, bal });
    }
}
