const std = @import("std");
const db_mod = @import("../database.zig");

test "system config toC compiles" {
    var cfg: db_mod.SystemConfig = .{ .buffer_pool_size = 1 << 20, .read_only = false };
    const c_cfg = cfg.toC();
    std.mem.doNotOptimizeAway(c_cfg);
}
