const std = @import("std");
const zkuzu = @import("../root.zig");
const util = @import("util.zig");

test "interrupt_timeout: timeout triggers error and message/category" {
    const a = std.testing.allocator;
    var fix = try util.DbFixture.init(a, "zig-cache/zkuzu-interrupt-timeout", "db");
    defer fix.deinit();

    // Keep this small to force a quick timeout on a heavy query
    try fix.conn.setTimeout(10); // 10 ms

    var timer = try util.Timer.start();
    const heavy = "UNWIND range(1, 10000000) AS i RETURN i";

    // Expect a timeout/interrupt style failure; success is unexpected here
    if (fix.conn.query(heavy)) |qr| {
        var tmp = qr;
        tmp.deinit();
        @panic("expected timeout failure for heavy query under small timeout");
    } else |err| {
        try std.testing.expectEqual(zkuzu.Error.QueryFailed, err);
    }

    _ = timer.elapsedMs(); // timing is platform/Kuzu-version dependent; do not assert

    // Validate we recorded an error message and/or categorized it
    if (fix.conn.lastError()) |e| {
        // Accept coarse categories; exact strings vary by Kuzu version
        const cat = e.category;
        try std.testing.expect(cat == .timeout or cat == .interrupt or cat == .unknown);
    } else {
        // Fallback to a non-empty message if structured error isn’t set
        if (fix.conn.lastErrorMessage()) |msg| {
            try std.testing.expect(msg.len > 0);
        } else {
            @panic("expected last error or last error message after timeout");
        }
    }
}
