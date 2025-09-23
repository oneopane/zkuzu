const std = @import("std");
const zkuzu = @import("zkuzu");

pub fn main() !void {
    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-example-errors", .{});
    var db = try zkuzu.open("zig-cache/zkuzu-example-errors/db", null);
    defer db.deinit();
    var conn = try db.connection();
    defer conn.deinit();

    // Intentionally invalid query
    _ = conn.query("RETURN 1 + ") catch |err| switch (err) {
        zkuzu.Error.QueryFailed => {
            if (conn.lastErrorMessage()) |msg| {
                std.debug.print("Query failed: {s}\n", .{msg});
            }
        },
        else => return err,
    };

    // Prepared statement bind error example
    var ps = try conn.prepare("RETURN $x");
    defer ps.deinit();
    // Bind a null with mismatched type to trigger binder error
    ps.bindNull("x", @intFromEnum(zkuzu.ValueType.Int64)) catch {
        if (conn.lastErrorMessage()) |msg| {
            std.debug.print("Bind failed: {s}\n", .{msg});
        }
    };
}
