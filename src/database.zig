const std = @import("std");
const bindings = @import("bindings.zig");
const errors = @import("errors.zig");
const connection_mod = @import("conn.zig");

const c = bindings.c;
const checkState = errors.checkState;
const Conn = connection_mod.Conn;

pub const SystemConfig = struct {
    buffer_pool_size: u64 = 1 << 30,
    max_num_threads: u64 = 0,
    enable_compression: bool = true,
    read_only: bool = false,
    max_db_size: u64 = 1 << 43,
    auto_checkpoint: bool = true,
    checkpoint_threshold: u64 = 1 << 26,

    /// Convert this `SystemConfig` to the C ABI `kuzu_system_config`.
    ///
    /// Parameters:
    /// - `self`: The configuration to convert
    ///
    /// Returns: A `c.kuzu_system_config` suitable for passing to Kuzu C APIs
    pub fn toC(self: SystemConfig) c.kuzu_system_config {
        return .{
            .buffer_pool_size = self.buffer_pool_size,
            .max_num_threads = self.max_num_threads,
            .enable_compression = self.enable_compression,
            .read_only = self.read_only,
            .max_db_size = self.max_db_size,
            .auto_checkpoint = self.auto_checkpoint,
            .checkpoint_threshold = self.checkpoint_threshold,
        };
    }

    /// Return the default `SystemConfig`.
    ///
    /// Returns: A zero-overrides configuration with sensible defaults
    ///
    /// Example:
    /// ```zig
    /// const cfg = zkuzu.SystemConfig.default();
    /// var db = try zkuzu.open("/tmp/db", cfg);
    /// ```
    pub fn default() SystemConfig {
        return .{};
    }
};

pub const Database = struct {
    db: c.kuzu_database,
    allocator: std.mem.Allocator,

    /// Open or create a Kuzu database at `path`.
    ///
    /// Parameters:
    /// - `path`: Zero-terminated filesystem path to the database directory
    /// - `config`: Optional `SystemConfig`; if null, uses Kuzu defaults
    ///
    /// Returns: An initialized `Database` handle. Call `deinit()` when done.
    ///
    /// Errors:
    /// - `Error.DatabaseInit`: If the underlying Kuzu initialization fails
    /// - `error.OutOfMemory`: If allocations fail
    ///
    /// Example:
    /// ```zig
    /// var db = try zkuzu.Database.init("zig-cache/mydb", null);
    /// defer db.deinit();
    /// ```
    pub fn init(path: [*:0]const u8, config: ?SystemConfig) !Database {
        var db: c.kuzu_database = undefined;
        const sys_config = if (config) |cfg| cfg.toC() else c.kuzu_default_system_config();

        const state = c.kuzu_database_init(path, sys_config, &db);
        try checkState(state);

        return .{
            .db = db,
            .allocator = std.heap.page_allocator,
        };
    }

    /// Close the database and release resources.
    ///
    /// Parameters:
    /// - `self`: Database handle to close
    ///
    /// Returns: Nothing
    pub fn deinit(self: *Database) void {
        c.kuzu_database_destroy(&self.db);
    }

    /// Create a new connection to the database.
    ///
    /// Each connection is intended for use by a single thread at a time.
    ///
    /// Parameters:
    /// - `self`: Database handle
    ///
    /// Returns: A connected `Conn` object. Call `conn.deinit()` to close it.
    ///
    /// Errors:
    /// - `Error.ConnectionInit`: If a connection cannot be established
    pub fn connection(self: *Database) !Conn {
        return Conn.init(&self.db, self.allocator);
    }
};
