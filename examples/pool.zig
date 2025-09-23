const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-example-pool", .{});
    var db = try zkuzu.open("zig-cache/zkuzu-example-pool/db", null);
    defer db.deinit();

    var pool = try zkuzu.Pool.init(alloc, &db, 4);
    defer pool.deinit();

    // Schema
    var _q = try pool.query("CREATE NODE TABLE IF NOT EXISTS Item(id INT64, PRIMARY KEY(id))");
    _q.deinit();

    // Insert with withTransaction (auto-commit on success)
    const TxR = zkuzu.Error || error{PoolExhausted};
    _ = try pool.withTransaction(TxR!void, .{}, struct {
        fn run(tx: *zkuzu.Transaction, _: @TypeOf(.{})) TxR!void {
            try tx.exec("MERGE (:Item {id: 1})");
            try tx.exec("MERGE (:Item {id: 2})");
            return;
        }
    }.run);

    // Read using withConnection
    const FnR = zkuzu.Error || error{PoolExhausted};
    _ = try pool.withConnection(FnR!void, .{}, struct {
        fn run(conn: *zkuzu.Conn, _: @TypeOf(.{})) FnR!void {
            var qr = try conn.query("MATCH (n:Item) RETURN n.id ORDER BY n.id");
            defer qr.deinit();
            while (try qr.next()) |row| : (row.deinit()) {
                const id = try row.getInt(0);
                std.debug.print("Item {d}\n", .{id});
            }
            return;
        }
    }.run);
}
