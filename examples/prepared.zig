const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    const db_path = "zig-cache/zkuzu-example-prepared/db";
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-example-prepared", .{});

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    try conn.exec("CREATE NODE TABLE IF NOT EXISTS Person(name STRING, age INT64, PRIMARY KEY(name))");
    try conn.exec("MERGE (:Person {name:'Alice', age:30})");
    try conn.exec("MERGE (:Person {name:'Bob', age:25})");

    var ps = try conn.prepare("MATCH (p:Person) WHERE p.age > $min_age RETURN p.name AS name, p.age AS age ORDER BY p.age DESC");
    defer ps.deinit();
    try ps.bindInt("min_age", 26);
    var qr = try ps.execute();
    defer qr.deinit();

    std.debug.print("People older than 26:\n", .{});
    while (try qr.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const name = try row.getByName([]const u8, "name");
        const age = try row.getByName(i64, "age");
        std.debug.print("- {s} ({d})\n", .{ name, age });
    }

    // Typed temporals
    const ts: zkuzu.c.kuzu_timestamp_t = .{ .value = 1612137600000 };
    var ps2 = try conn.prepare("RETURN $ts AS ts, $iv AS iv");
    defer ps2.deinit();
    try ps2.bindTimestamp("ts", ts);
    try ps2.bindInterval("iv", .{ .months = 1, .days = 2, .micros = 3 });
    var qr2 = try ps2.execute();
    defer qr2.deinit();
    if (try qr2.next()) |row_val2| {
        const row2 = row_val2;
        defer row2.deinit();
        const ts_out = try row2.getTimestamp(0);
        const iv_out = try row2.getInterval(1);
        std.debug.print("ts.value={}, interval.months={}\n", .{ ts_out.value, iv_out.months });
    }
}
