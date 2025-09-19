const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    var db = try zkuzu.open("zig-cache/zkuzu-example-perf/db", null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    // Tune execution
    try conn.setMaxThreads(0); // let Kuzu decide
    try conn.setTimeout(10_000); // 10s

    // Schema
    _ = try conn.query("CREATE NODE TABLE IF NOT EXISTS Log(id INT64, msg STRING, PRIMARY KEY(id))");

    // Use prepared statements for bulk inserts (reduces parsing/binding cost)
    var ps = try conn.prepare("MERGE (:Log {id: $id, msg: $msg})");
    defer ps.deinit();

    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        try ps.bindInt("id", i);
        try ps.bindString("msg", "hello");
        var r = try ps.execute();
        r.deinit();
    }

    // Borrow vs copy: prefer borrowed when possible
    var qr = try conn.query("MATCH (l:Log) RETURN l.msg LIMIT 1");
    defer qr.deinit();
    if (try qr.next()) |row| {
        defer row.deinit();
        const borrowed = try row.getString(0); // no extra allocation
        _ = borrowed;
        // If you must keep after row.deinit(), make a copy:
        const owned_opt = try row.copyString(std.heap.page_allocator, 0);
        if (owned_opt) |owned| std.heap.page_allocator.free(owned);
    }
}
