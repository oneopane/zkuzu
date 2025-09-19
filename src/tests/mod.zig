const std = @import("std");

comptime {
    _ = @import("root.zig");
    _ = @import("pool.zig");
    _ = @import("bindings.zig");
    _ = @import("database.zig");
    _ = @import("conn.zig");
    _ = @import("prepared_statement.zig");
    _ = @import("query_result.zig");
    _ = @import("strings.zig");
    _ = @import("errors.zig");
    _ = @import("util.zig");
    _ = @import("integration.zig");
    _ = @import("edge_cases.zig");
    _ = @import("transactions.zig");
}
