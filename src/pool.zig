const std = @import("std");
const zkuzu = @import("root.zig");
const Database = zkuzu.Database;
const Conn = zkuzu.Conn;
const Error = @import("errors.zig").Error;

// Transaction helper that scopes BEGIN/COMMIT/ROLLBACK around a pooled connection
pub const Transaction = struct {
    conn: *Conn,
    active: bool = false,

    pub fn init(conn: *Conn) Transaction {
        return .{ .conn = conn, .active = true };
    }

    pub fn isActive(self: *Transaction) bool {
        return self.active;
    }

    pub fn ensureActive(self: *Transaction) !void {
        if (!self.active) return Error.TransactionAlreadyClosed;
    }

    pub fn query(self: *Transaction, q: []const u8) !zkuzu.QueryResult {
        try self.ensureActive();
        return try self.conn.query(q);
    }

    pub fn exec(self: *Transaction, q: []const u8) !void {
        try self.ensureActive();
        try self.conn.exec(q);
    }

    pub fn prepare(self: *Transaction, q: []const u8) !zkuzu.PreparedStatement {
        try self.ensureActive();
        return try self.conn.prepare(q);
    }

    pub fn commit(self: *Transaction) !void {
        try self.ensureActive();
        defer self.active = false;
        try self.conn.commit();
    }

    pub fn rollback(self: *Transaction) !void {
        try self.ensureActive();
        defer self.active = false;
        try self.conn.rollback();
    }

    // Ensure rollback if still active; swallow rollback errors
    pub fn close(self: *Transaction) void {
        if (self.active) {
            self.conn.rollback() catch {};
            self.active = false;
        }
    }
};

// Connection pool for managing multiple connections
pub const Pool = struct {
    const PooledConn = struct {
        conn: Conn,
        in_use: bool,
        last_used: i64,
    };

    database: *Database,
    connections: std.ArrayListUnmanaged(PooledConn),
    max_connections: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, database: *Database, max_connections: usize) !Pool {
        return .{
            .database = database,
            .connections = .{},
            .max_connections = max_connections,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*pooled| {
            pooled.conn.deinit();
        }
        self.connections.deinit(self.allocator);
    }

    // Acquire a connection from the pool
    pub fn acquire(self: *Pool) !Conn {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Look for an available connection
        for (self.connections.items) |*pooled| {
            if (!pooled.in_use) {
                pooled.in_use = true;
                pooled.last_used = now;
                return pooled.conn;
            }
        }

        // Create a new connection if we haven't reached the limit
        if (self.connections.items.len < self.max_connections) {
            var conn = try self.database.connection();
            errdefer conn.deinit();
            try self.connections.append(self.allocator, .{
                .conn = conn,
                .in_use = true,
                .last_used = now,
            });
            return conn;
        }

        // All connections are in use and we've reached the limit
        return error.PoolExhausted;
    }

    // Release a connection back to the pool
    pub fn release(self: *Pool, conn: Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*pooled| {
            // Compare underlying C connection handles
            if (@intFromPtr(pooled.conn.conn._connection) == @intFromPtr(conn.conn._connection)) {
                pooled.in_use = false;
                pooled.last_used = std.time.timestamp();
                break;
            }
        }
    }

    // Execute a query using a pooled connection
    pub fn query(self: *Pool, query_str: []const u8) !zkuzu.QueryResult {
        var conn = try self.acquire();
        defer self.release(conn);
        return try conn.query(query_str);
    }

    // Execute a function with a pooled connection
    pub fn withConnection(self: *Pool, comptime T: type, context: anytype, func: fn (conn: *Conn, ctx: @TypeOf(context)) T) T {
        comptime switch (@typeInfo(T)) {
            .error_union => {},
            else => @compileError("withConnection requires an error-union return type"),
        };

        var conn = self.acquire() catch |err| {
            return err;
        };
        defer self.release(conn);
        return func(&conn, context);
    }

    // Execute a function within a transaction using a pooled connection
    pub fn withTransaction(self: *Pool, comptime T: type, context: anytype, func: fn (tx: *Transaction, ctx: @TypeOf(context)) T) T {
        comptime switch (@typeInfo(T)) {
            .error_union => {},
            else => @compileError("withTransaction requires an error-union return type"),
        };

        var conn = self.acquire() catch |err| {
            return err;
        };
        defer self.release(conn);

        // Begin transaction
        conn.beginTransaction() catch |err| {
            return err;
        };

        var tx = Transaction.init(&conn);

        const result = func(&tx, context) catch |cb_err| {
            if (tx.isActive()) tx.rollback() catch {};
            return cb_err;
        };

        // If user hasn't already closed, commit. On commit failure, attempt rollback.
        if (tx.isActive()) {
            tx.commit() catch |commit_err| {
                // Best-effort rollback if commit failed
                if (tx.isActive()) tx.rollback() catch {};
                return commit_err;
            };
        }

        return result;
    }

    // Get pool statistics
    pub fn getStats(self: *Pool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var in_use: usize = 0;
        for (self.connections.items) |pooled| {
            if (pooled.in_use) in_use += 1;
        }

        return .{
            .total_connections = self.connections.items.len,
            .in_use = in_use,
            .available = self.connections.items.len - in_use,
            .max_connections = self.max_connections,
        };
    }

    // Clean up idle connections
    pub fn cleanupIdle(self: *Pool, max_idle_seconds: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var i: usize = 0;

        while (i < self.connections.items.len) {
            const pooled = &self.connections.items[i];
            if (!pooled.in_use and (now - pooled.last_used) > max_idle_seconds) {
                pooled.conn.deinit();
                // ordered remove
                const last_index = self.connections.items.len - 1;
                self.connections.items[i] = self.connections.items[last_index];
                _ = self.connections.pop();
            } else {
                i += 1;
            }
        }
    }
};

pub const PoolStats = struct {
    total_connections: usize,
    in_use: usize,
    available: usize,
    max_connections: usize,
};
