const std = @import("std");

pub fn toCString(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    return try allocator.dupeZ(u8, str);
}
