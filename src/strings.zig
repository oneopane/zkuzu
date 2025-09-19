const std = @import("std");

/// Convert a Zig slice to a C-compatible, NUL-terminated string.
///
/// Allocates a new buffer that owns a zero-terminated copy of `str` using the
/// provided `allocator`. The caller owns the returned memory and must free it
/// with the same allocator.
///
/// Parameters:
/// - `allocator`: Allocator used to create the zero-terminated buffer
/// - `str`: Input UTF-8 byte slice to duplicate
///
/// Returns: Newly allocated `[:0]const u8` C string
///
/// Errors:
/// - `error.OutOfMemory`: If allocation fails
///
/// Example:
/// ```zig
/// const cstr = try zkuzu.toCString(alloc, "MATCH (n) RETURN 1");
/// defer alloc.free(cstr);
/// ```
pub fn toCString(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    return try allocator.dupeZ(u8, str);
}
