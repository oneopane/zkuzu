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
    connections: std.ArrayListUnmanaged(*PooledConn),
    max_connections: usize,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    tx_mutex: std.Thread.Mutex,
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
            .cond = std.Thread.Condition{},
            .tx_mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    /// Destroy the pool and close all managed connections.
    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |pooled| {
            pooled.conn.deinit();
            self.allocator.destroy(pooled);
        }
        self.connections.deinit(self.allocator);
    }

    // Acquire a connection from the pool
    /// Acquire a connection from the pool (may create a new one).
    ///
    /// Returns: Pointer to a pooled connection; hand it back to `release` when done.
    ///
    /// Errors:
    /// - `error.PoolExhausted`: If all connections are busy and at capacity
    /// - `zkuzu.Error.ConnectionInit`: If creating a new connection fails
    pub fn acquire(self: *Pool) !*Conn {
        var attempted_create = false;

        while (true) {
            self.mutex.lock();
            const now = std.time.timestamp();

            // Look for an idle connection first.
            var pick: ?usize = null;
            var i: usize = 0;
            while (i < self.connections.items.len) : (i += 1) {
                if (!self.connections.items[i].in_use) {
                    pick = i;
                    break;
                }
            }

            if (pick) |idx| {
                const pooled = self.connections.items[idx];
                pooled.in_use = true;
                pooled.last_used = now;
                const conn_ptr = &pooled.conn;
                self.mutex.unlock();

                // Validate outside the lock; recover or replace on demand.
                conn_ptr.validate() catch {
                    conn_ptr.recover() catch {};
                    conn_ptr.validate() catch {
                        var replacement = try self.database.connection();
                        errdefer replacement.deinit();

                        self.mutex.lock();
                        pooled.conn.deinit();
                        pooled.conn = replacement;
                        pooled.last_used = std.time.timestamp();
                        self.mutex.unlock();
                        return &pooled.conn;
                    };
                    return conn_ptr;
                };
                return conn_ptr;
            }

            // No idle connection. If we can grow and we haven't tried yet, do so.
            if (!attempted_create and self.connections.items.len < self.max_connections) {
                self.mutex.unlock();

                var conn = try self.database.connection();
                errdefer conn.deinit();
                conn.validate() catch {};

                var pooled = try self.allocator.create(PooledConn);
                errdefer {
                    pooled.conn.deinit();
                    self.allocator.destroy(pooled);
                }
                pooled.* = .{
                    .conn = conn,
                    .in_use = true,
                    .last_used = std.time.timestamp(),
                };

                self.mutex.lock();
                if (self.connections.items.len < self.max_connections) {
                    try self.connections.append(self.allocator, pooled);
                    self.mutex.unlock();
                    return &pooled.conn;
                }
                self.mutex.unlock();

                // Pool filled up while we were creating a new connection.
                pooled.conn.deinit();
                self.allocator.destroy(pooled);
                attempted_create = true;
                continue;
            }

            // Pool saturated; wait until a connection is released.
            self.cond.wait(&self.mutex);
            self.mutex.unlock();
        }
    }

    /// Try to acquire a connection without blocking. Returns PoolExhausted if none available.
    pub fn tryAcquire(self: *Pool) !*Conn {
        var attempted_create = false;

        // Single pass that mirrors `acquire` logic, but without waiting.
        self.mutex.lock();
        const now = std.time.timestamp();

        // Look for an idle connection first.
        var pick: ?usize = null;
        var i: usize = 0;
        while (i < self.connections.items.len) : (i += 1) {
            if (!self.connections.items[i].in_use) {
                pick = i;
                break;
            }
        }

        if (pick) |idx| {
            const pooled = self.connections.items[idx];
            pooled.in_use = true;
            pooled.last_used = now;
            const conn_ptr = &pooled.conn;
            self.mutex.unlock();

            // Validate outside the lock; recover or replace on demand.
            conn_ptr.validate() catch {
                conn_ptr.recover() catch {};
                conn_ptr.validate() catch {
                    var replacement = try self.database.connection();
                    errdefer replacement.deinit();

                    self.mutex.lock();
                    pooled.conn.deinit();
                    pooled.conn = replacement;
                    pooled.last_used = std.time.timestamp();
                    self.mutex.unlock();
                    return &pooled.conn;
                };
                return conn_ptr;
            };
            return conn_ptr;
        }

        // No idle connection. If we can grow and we haven't tried yet, do so.
        if (!attempted_create and self.connections.items.len < self.max_connections) {
            self.mutex.unlock();

            var conn = try self.database.connection();
            errdefer conn.deinit();
            conn.validate() catch {};

            var pooled = try self.allocator.create(PooledConn);
            errdefer {
                pooled.conn.deinit();
                self.allocator.destroy(pooled);
            }
            pooled.* = .{
                .conn = conn,
                .in_use = true,
                .last_used = std.time.timestamp(),
            };

            self.mutex.lock();
            if (self.connections.items.len < self.max_connections) {
                try self.connections.append(self.allocator, pooled);
                self.mutex.unlock();
                return &pooled.conn;
            }
            self.mutex.unlock();

            // Pool filled up while we were creating a new connection.
            pooled.conn.deinit();
            self.allocator.destroy(pooled);
            attempted_create = true;
        } else {
            self.mutex.unlock();
        }

        // At capacity and none available.
        return error.PoolExhausted;
    }

    // Release a connection back to the pool
    /// Return a previously acquired connection back to the pool.
    pub fn release(self: *Pool, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |pooled| {
            if (&pooled.conn == conn) {
                pooled.in_use = false;
                pooled.last_used = std.time.timestamp();
                self.cond.signal();
                break;
            }
        }
    }

    // Execute a query using a pooled connection
    /// Convenience: acquire, query, release.
    pub fn query(self: *Pool, query_str: []const u8) !zkuzu.QueryResult {
        const conn = try self.acquire();
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

        const conn = self.acquire() catch |err| {
            return err;
        };
        defer self.release(conn);
        return func(conn, context);
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

        // Avoid deadlock when pool size is 1: do not block.
        const conn = if (self.max_connections == 1)
            self.tryAcquire() catch |err| return err
        else
            self.acquire() catch |err| return err;
        defer self.release(conn);

        self.tx_mutex.lock();
        var tx_lock_held = true;
        defer if (tx_lock_held) self.tx_mutex.unlock();

        // Begin transaction (serialized by tx_mutex)
        conn.beginTransaction() catch |err| {
            tx_lock_held = false;
            self.tx_mutex.unlock();
            return err;
        };

        var tx = Transaction.init(conn);

        const result = func(&tx, context) catch |cb_err| {
            if (tx.isActive()) tx.rollback() catch {};
            tx_lock_held = false;
            self.tx_mutex.unlock();
            return cb_err;
        };

        // If user hasn't already closed, commit. On commit failure, attempt rollback.
        if (tx.isActive()) {
            tx.commit() catch |commit_err| {
                // Best-effort rollback if commit failed
                if (tx.isActive()) tx.rollback() catch {};
                tx_lock_held = false;
                self.tx_mutex.unlock();
                return commit_err;
            };
        }

        tx_lock_held = false;
        self.tx_mutex.unlock();
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
            const pooled = self.connections.items[i];
            if (!pooled.in_use and (now - pooled.last_used) > max_idle_seconds) {
                _ = self.connections.swapRemove(i);
                pooled.conn.deinit();
                self.allocator.destroy(pooled);
                continue;
            }
            i += 1;
        }
    }

    // Health check all pooled connections
    /// Validate all pooled connections (best-effort), replacing failed ones on next acquire.
    pub fn healthCheckAll(self: *Pool) !void {
        self.mutex.lock();
        const len = self.connections.items.len;
        var snapshots = try self.allocator.alloc(*Conn, len);
        defer self.allocator.free(snapshots);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const pooled = self.connections.items[i];
            snapshots[i] = &pooled.conn;
        }
        self.mutex.unlock();

        for (snapshots) |conn_ptr| {
            conn_ptr.validate() catch {};
        }
    }
};

pub const PoolStats = struct {
    total_connections: usize,
    in_use: usize,
    available: usize,
    max_connections: usize,
};
