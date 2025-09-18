const std = @import("std");
const zkuzu = @import("src/root.zig");

pub fn main() !void {

    // Create or open database
    var db = try zkuzu.open("example.kuzu", null);
    defer db.deinit();

    // Create connection
    var conn = try db.connection();
    defer conn.deinit();

    // Create a simple graph
    _ = try conn.query("CREATE NODE TABLE IF NOT EXISTS User(id INT64, name STRING, PRIMARY KEY(id))");
    _ = try conn.query("CREATE REL TABLE IF NOT EXISTS Follows(FROM User TO User)");

    // Insert some data
    _ = try conn.query("MERGE (:User {id: 1, name: 'Alice'})");
    _ = try conn.query("MERGE (:User {id: 2, name: 'Bob'})");
    _ = try conn.query("MERGE (:User {id: 3, name: 'Charlie'})");

    _ = try conn.query("MATCH (a:User {id: 1}), (b:User {id: 2}) MERGE (a)-[:Follows]->(b)");
    _ = try conn.query("MATCH (b:User {id: 2}), (c:User {id: 3}) MERGE (b)-[:Follows]->(c)");

    // Query the graph
    std.debug.print("Users in the graph:\n", .{});
    var result = try conn.query("MATCH (u:User) RETURN u.id, u.name ORDER BY u.id");
    defer result.deinit();

    while (try result.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const id = try row.getInt(0);
        const name = try row.getString(1);
        std.debug.print("  User {}: {s}\n", .{ id, name });
    }

    std.debug.print("\nWho follows whom:\n", .{});
    var result2 = try conn.query("MATCH (a:User)-[:Follows]->(b:User) RETURN a.name, b.name");
    defer result2.deinit();

    while (try result2.next()) |row_val| {
        const row = row_val;
        defer row.deinit();
        const follower = try row.getString(0);
        const followed = try row.getString(1);
        std.debug.print("  {s} follows {s}\n", .{ follower, followed });
    }

    std.debug.print("\nDemonstrating error reporting...\n", .{});
    const invalid_result = blk: {
        const res = conn.query("RETURN 1 +") catch |err| switch (err) {
            zkuzu.Error.QueryFailed => {
                if (conn.lastErrorMessage()) |msg| {
                    std.debug.print("  Query failed with message: {s}\n", .{msg});
                } else {
                    std.debug.print("  Query failed without message\n", .{});
                }
                break :blk null;
            },
            else => return err,
        };
        break :blk res;
    };
    if (invalid_result) |qr_bad| {
        defer qr_bad.deinit();
        std.debug.print("  Unexpected success for invalid query\n", .{});
    }

    std.debug.print("\nzkuzu wrapper working successfully!\n", .{});
}
