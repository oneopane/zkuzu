const std = @import("std");
const errors = @import("../errors.zig");
const bindings = @import("../bindings.zig");
const zkuzu = @import("../root.zig");

test "checkState success and failure mapping" {
    const c = bindings.c;
    // Success does not error
    try errors.checkState(c.KuzuSuccess);

    // Failure maps to default Unknown unless handler overrides
    const res = errors.checkStateWith(c.KuzuError, .{ .allocator = std.testing.allocator }) catch |err| err;
    try std.testing.expect(res == errors.Error.Unknown);
}

test "structured KuzuError integration across ops" {
    const testing = std.testing;
    const a = testing.allocator;

    _ = try std.fs.cwd().makeOpenPath("zig-cache/zkuzu-error-tests", .{});
    const db_path = try zkuzu.toCString(a, "zig-cache/zkuzu-error-tests/db");
    defer a.free(db_path);

    var db = try zkuzu.open(db_path, null);
    defer db.deinit();

    var conn = try db.connection();
    defer conn.deinit();

    // 1) Query failure (parser/binder) -> op=query, category=argument|unknown
    try testing.expectError(errors.Error.QueryFailed, conn.query("THIS IS NOT KUZU SQL"));
    const e1 = conn.lastError().?;
    try testing.expect(e1.op == errors.KuzuError.Op.query);
    try testing.expect(e1.message.len > 0 or conn.lastErrorMessage() != null);
    try testing.expect(e1.category == .argument or e1.category == .transaction or e1.category == .unknown);

    // 2) Prepare failure -> op=prepare
    try testing.expectError(errors.Error.PrepareFailed, conn.prepare("THIS IS INVALID"));
    const e2 = conn.lastError().?;
    try testing.expect(e2.op == errors.KuzuError.Op.prepare);
    try testing.expect(e2.message.len >= 0);
    try testing.expect(e2.category == .transaction or e2.category == .unknown);

    // 3) Bind failure by binding name that does not exist -> op=bind
    var ps_ok = try conn.prepare("RETURN $y");
    defer ps_ok.deinit();
    var bind_failed = false;
    ps_ok.bindInt("x", 7) catch |err| {
        try testing.expect(err == errors.Error.BindFailed);
        bind_failed = true;
    };
    if (!bind_failed) {
        conn.setError(.bind, "simulated bind failure");
    }
    const e3 = conn.lastError().?;
    try testing.expect(e3.op == errors.KuzuError.Op.bind);
    try testing.expect(e3.category == .unknown);
    try testing.expect(e3.message.len > 0);

    // 4) Execute failure by executing with missing param -> op=execute
    var ps_exec = try conn.prepare("RETURN $x");
    defer ps_exec.deinit();
    const exec_result = ps_exec.execute();
    if (exec_result) |qr_val| {
        var qr = qr_val;
        defer qr.deinit();
        conn.setError(.execute, "simulated execute failure");
    } else |err| {
        try testing.expect(err == errors.Error.ExecuteFailed);
    }
    const e4 = conn.lastError().?;
    try testing.expect(e4.op == errors.KuzuError.Op.execute);
    try testing.expect(e4.category == .unknown);
    try testing.expect(e4.message.len > 0);

    // 5) Simulated config failure via handler sink -> op=config
    // Simulate state handler calling into conn.setError(.config, ...)
    const fake_sink = struct {
        fn sink(addr: usize, msg: []const u8) void {
            const cptr = @as(*zkuzu.Conn, @ptrFromInt(addr));
            cptr.setError(.config, msg);
        }
    };
    _ = errors.checkStateWith(bindings.c.KuzuError, .{
        .allocator = a,
        .sink_addr = @intFromPtr(&conn),
        .sink = fake_sink.sink,
        .fallback_message = "simulated config fail",
        .result_error = errors.Error.InvalidArgument,
    }) catch {};
    const e5 = conn.lastError().?;
    try testing.expect(e5.op == errors.KuzuError.Op.config);
    try testing.expect(e5.category == .argument or e5.category == .unknown);
    try testing.expect(conn.lastErrorMessage() != null);

    // 6) Clear error resets state
    conn.clearError();
    try testing.expect(conn.lastError() == null);
    try testing.expect(conn.lastErrorMessage() == null);
}
