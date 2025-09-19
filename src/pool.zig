const std = @import("std");
const zkuzu = @import("root.zig");
const Database = zkuzu.Database;
const Conn = zkuzu.Conn;
const Error = @import("errors.zig").Error;

// Transaction helper that scopes BEGIN/COMMIT/ROLLBACK around a pooled connection
/// Lightweight transaction wrapper used with `Pool.withTransaction` or manually.
///
/// A `Transaction` borrows a `Conn` from the pool and ensures `commit()` or
/// `rollback()` is called exactly once. Use `close()` to roll back if still
/// active, swallowing errors.
pub const Transaction = struct {
    conn: *Conn,
    active: bool = false,

    /// Create an active transaction wrapper for `conn`.
    /// Caller must call `commit()` or `rollback()` (or `close()`).
    pub fn init(conn: *Conn) Transaction {
        return .{ .conn = conn, .active = true };
    }

    /// Whether the transaction is still active.
    pub fn isActive(self: *Transaction) bool {
        return self.active;
    }

    /// Error if the transaction is already closed.
    ///
    /// Errors: `Error.TransactionAlreadyClosed`
    pub fn ensureActive(self: *Transaction) !void {
        if (!self.active) return Error.TransactionAlreadyClosed;
    }

    /// Execute a query within this transaction.
    pub fn query(self: *Transaction, q: []const u8) !zkuzu.QueryResult {
        try self.ensureActive();
        return try self.conn.query(q);
    }

    /// Execute a statement (without rows) within this transaction.
    pub fn exec(self: *Transaction, q: []const u8) !void {
        try self.ensureActive();
        try self.conn.exec(q);
    }

    /// Prepare a statement within this transaction.
    pub fn prepare(self: *Transaction, q: []const u8) !zkuzu.PreparedStatement {
        try self.ensureActive();
        return try self.conn.prepare(q);
    }

    /// Commit this transaction and mark it inactive.
    pub fn commit(self: *Transaction) !void {
        try self.ensureActive();
        defer self.active = false;
        try self.conn.commit();
    }

    /// Roll back this transaction and mark it inactive.
    pub fn rollback(self: *Transaction) !void {
        try self.ensureActive();
        defer self.active = false;
        try self.conn.rollback();
    }

    /// Ensure rollback if still active; swallow rollback errors.
    ///
    /// Parameters:
    /// - `self`: Transaction wrapper to close
    ///
    /// Returns: Nothing. If the transaction is still active, performs a
    /// best-effort rollback and marks it inactive.
    pub fn close(self: *Transaction) void {
        if (self.active) {
            self.conn.rollback() catch {};
            self.active = false;
        }
    }
};

// Connection pool for managing multiple connections
/// A simple connection pool for `zkuzu.Conn` with validation and recycling.
///
/// Acquire with `acquire()` and return with `release()`, or use
/// `withConnection` and `withTransaction` helpers to scope usage safely.
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

    /// Initialize a connection pool.
    ///
    /// Parameters:
    /// - `allocator`: Storage for internal arrays and temporaries
    /// - `database`: Backing database for new connections
    /// - `max_connections`: Maximum pool size
    pub fn init(allocator: std.mem.Allocator, database: *Database, max_connections: usize) !Pool {
        return .{
            .database = database,
            .connections = .{},
            .max_connections = max_connections,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    /// Destroy the pool and close all managed connections.
    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*pooled| {
            pooled.conn.deinit();
        }
        self.connections.deinit(self.allocator);
    }

    // Acquire a connection from the pool
    /// Acquire a connection from the pool (may create a new one).
    ///
    /// Returns: `Conn` value; pass it back to `release(conn)` when done.
    ///
    /// Errors:
    /// - `error.PoolExhausted`: If all connections are busy and at capacity
    /// - `zkuzu.Error.ConnectionInit`: If creating a new connection fails
    pub fn acquire(self: *Pool) !Conn {
        self.mutex.lock();

        const now = std.time.timestamp();

        // Look for an available connection
        var idx: ?usize = null;
        var i: usize = 0;
        while (i < self.connections.items.len) : (i += 1) {
            if (!self.connections.items[i].in_use) {
                idx = i;
                break;
            }
        }
        if (idx) |pick| {
            var pooled_ptr = &self.connections.items[pick];
            var tmp = pooled_ptr.conn;
            pooled_ptr.in_use = true;
            pooled_ptr.last_used = now;
            self.mutex.unlock();

            // Validate outside the lock
            if (tmp.validate()) |_| {
                return tmp;
            } else |_| {
                // Attempt recovery then re-validate
                tmp.recover() catch {};
                if (tmp.validate()) |_| {
                    return tmp;
                }
                // Replacement path
                var new_conn = try self.database.connection();
                // Update pooled slot with the new connection
                self.mutex.lock();
                self.connections.items[pick].conn.deinit();
                self.connections.items[pick].conn = new_conn;
                self.connections.items[pick].in_use = true;
                self.connections.items[pick].last_used = std.time.timestamp();
                self.mutex.unlock();
                return new_conn;
            }
        }

        // Create a new connection if we haven't reached the limit
        if (self.connections.items.len < self.max_connections) {
            var conn = try self.database.connection();
            errdefer conn.deinit();
            // Validate new connection right away (best-effort)
            conn.validate() catch {};
            if (self.connections.append(self.allocator, .{
                .conn = conn,
                .in_use = true,
                .last_used = now,
            })) |_| {
                self.mutex.unlock();
                return conn;
            } else |append_err| {
                self.mutex.unlock();
                conn.deinit();
                return append_err;
            }
        }

        // All connections are in use and we've reached the limit
        self.mutex.unlock();
        return error.PoolExhausted;
    }

    // Release a connection back to the pool
    /// Return a previously acquired connection back to the pool.
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
    /// Convenience: acquire, query, release.
    pub fn query(self: *Pool, query_str: []const u8) !zkuzu.QueryResult {
        var conn = try self.acquire();
        defer self.release(conn);
        return try conn.query(query_str);
    }

    // Execute a function with a pooled connection
    /// Run `func(conn, context)` with a pooled connection, releasing afterwards.
    ///
    /// Parameters:
    /// - `T`: Error-union return type of the callback
    /// - `context`: Arbitrary context passed to the callback
    /// - `func`: Callback that receives `*Conn` and `context`
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
    /// Run `func(tx, context)` inside a transaction with automatic commit/rollback.
    ///
    /// On callback success, commits (if still active). On error, rolls back.
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
    /// Snapshot current pool counters.
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
    /// Close and remove idle connections older than `max_idle_seconds`.
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

    // Health check all pooled connections
    /// Validate all pooled connections (best-effort), replacing failed ones on next acquire.
    pub fn healthCheckAll(self: *Pool) !void {
        self.mutex.lock();
        const len = self.connections.items.len;
        var snapshots = try self.allocator.alloc(Conn, len);
        defer self.allocator.free(snapshots);
        var i: usize = 0;
        while (i < len) : (i += 1) snapshots[i] = self.connections.items[i].conn;
        self.mutex.unlock();

        for (snapshots) |*cconn| {
            cconn.validate() catch {};
        }
    }
};

pub const PoolStats = struct {
    total_connections: usize,
    in_use: usize,
    available: usize,
    max_connections: usize,
};
