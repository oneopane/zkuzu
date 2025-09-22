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
    _ = @import("constraints.zig");
    _ = @import("pool_lifecycle.zig");
    // Note: interrupt/timeout tests are omitted to keep the suite fast and deterministic.
}
