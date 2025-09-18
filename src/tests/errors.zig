const std = @import("std");
const errors = @import("../errors.zig");
const bindings = @import("../bindings.zig");

test "checkState success and failure mapping" {
    const c = bindings.c;
    // Success does not error
    try errors.checkState(c.KuzuSuccess);

    // Failure maps to default Unknown unless handler overrides
    const res = errors.checkStateWith(c.KuzuError, .{ .allocator = std.testing.allocator }) catch |err| err;
    try std.testing.expect(res == errors.Error.Unknown);
}

