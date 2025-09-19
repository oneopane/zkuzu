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
    const q1 = conn.query("THIS IS NOT KUZU SQL") catch |e| e;
    try testing.expect(q1 == errors.Error.QueryFailed);
    const e1 = conn.lastError().?;
    try testing.expect(e1.op == errors.KuzuError.Op.query);
    try testing.expect(e1.message.len > 0 or conn.lastErrorMessage() != null);
    try testing.expect(e1.category == .argument or e1.category == .unknown);

    // 2) Prepare failure -> op=prepare
    const ps_bad = conn.prepare("THIS IS INVALID") catch |e| e;
    try testing.expect(ps_bad == errors.Error.PrepareFailed);
    const e2 = conn.lastError().?;
    try testing.expect(e2.op == errors.KuzuError.Op.prepare);
    try testing.expect(e2.message.len >= 0);

    // 3) Bind failure by binding name that does not exist -> op=bind
    var ps_ok = try conn.prepare("RETURN $y");
    defer ps_ok.deinit();
    const bind_res = ps_ok.bindInt("x", 7) catch |e| e;
    try testing.expect(bind_res == errors.Error.BindFailed);
    const e3 = conn.lastError().?;
    try testing.expect(e3.op == errors.KuzuError.Op.bind);

    // 4) Execute failure by executing with missing param -> op=execute
    var ps_exec = try conn.prepare("RETURN $x");
    defer ps_exec.deinit();
    const exec_res = ps_exec.execute() catch |e| e;
    try testing.expect(exec_res == errors.Error.ExecuteFailed);
    const e4 = conn.lastError().?;
    try testing.expect(e4.op == errors.KuzuError.Op.execute);

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
