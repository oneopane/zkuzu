const std = @import("std");
const bindings = @import("../bindings.zig");

test "bindings import" {
    _ = bindings.c; // ensure C header is wired
}

