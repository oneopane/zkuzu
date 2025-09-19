const std = @import("std");
const strings = @import("../strings.zig");

test "toCString allocates zero-terminated" {
    const a = std.testing.allocator;
    const s = try strings.toCString(a, "abc");
    defer a.free(s);
    try std.testing.expectEqual(@as(u8, 0), s[3]);
}
