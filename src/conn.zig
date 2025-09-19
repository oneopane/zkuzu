const std = @import("std");
const bindings = @import("bindings.zig");
const errors = @import("errors.zig");
const strings = @import("strings.zig");
const query_result = @import("query_result.zig");
const prepared_statement = @import("prepared_statement.zig");

const c = bindings.c;
const Error = errors.Error;
const checkState = errors.checkState;
const checkStateWith = errors.checkStateWith;
const toCString = strings.toCString;
const QueryResult = query_result.QueryResult;
const KuzuError = errors.KuzuError;

pub const Conn = struct {
    conn: c.kuzu_connection,
    allocator: std.mem.Allocator,
    last_error_message: ?[]u8 = null,
    err: ?KuzuError = null,
    _err_data: ?[]u8 = null,

    pub fn init(db_handle: *c.kuzu_database, allocator: std.mem.Allocator) !Conn {
        var conn_handle: c.kuzu_connection = undefined;
        const state = c.kuzu_connection_init(db_handle, &conn_handle);
        try checkState(state);

        return .{
            .conn = conn_handle,
            .allocator = allocator,
            .last_error_message = null,
        };
    }

    pub fn deinit(self: *Conn) void {
        self.clearError();
        c.kuzu_connection_destroy(&self.conn);
    }

    fn releaseLastErrorMessage(self: *Conn) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
            self.last_error_message = null;
        }
    }

    pub fn setLastErrorMessage(self: *Conn, msg_opt: ?[]u8) void {
        self.releaseLastErrorMessage();
        if (msg_opt) |msg| {
            self.last_error_message = msg;
        }
    }

    pub fn setLastErrorMessageCopy(self: *Conn, msg: []const u8) void {
        const copy = self.allocator.dupe(u8, msg) catch {
            self.setLastErrorMessage(null);
            return;
        };
        self.setLastErrorMessage(copy);
    }

    fn stateMessageSink(addr: usize, msg: []const u8) void {
        const conn_ptr = @as(*Conn, @ptrFromInt(addr));
        conn_ptr.setError(.config, msg);
    }

    fn makeStateHandler(self: *Conn, fallback: []const u8, err: Error) errors.StateErrorHandler {
        return .{
            .allocator = self.allocator,
            .sink_addr = @intFromPtr(self),
            .sink = stateMessageSink,
            .fallback_message = fallback,
            .result_error = err,
        };
    }

    pub fn lastErrorMessage(self: *Conn) ?[]const u8 {
        if (self.last_error_message) |msg| {
            return msg;
        }
        return null;
    }

    pub fn lastError(self: *Conn) ?*const KuzuError {
        if (self.err) |*e| return e; else return null;
    }

    pub fn clearError(self: *Conn) void {
        if (self.err) |*e| {
            e.deinit();
            self.err = null;
        }
        if (self._err_data) |buf| {
            self.allocator.free(buf);
            self._err_data = null;
        }
        self.releaseLastErrorMessage();
    }

    pub fn setError(self: *Conn, op: KuzuError.Op, msg: []const u8) void {
        // Reset previous error state
        self.clearError();
        // Build structured error (best-effort; avoid throwing here)
        var new_err: ?KuzuError = null;
        new_err = KuzuError.init(self.allocator, op, msg) catch null;
        if (new_err) |e| {
            // Keep a copy of message for backward compatibility
            // Note: e.message is owned; duplicate for last_error_message independently.
            // If duplication fails, we still keep structured error.
            self.last_error_message = self.allocator.dupe(u8, e.message) catch null;
            self.err = e;
        } else {
            // Fall back to legacy message only
            self.setLastErrorMessageCopy(msg);
        }
    }

    pub fn query(self: *Conn, query_str: []const u8) !QueryResult {
        const c_query = try toCString(self.allocator, query_str);
        defer self.allocator.free(c_query);

        self.clearError();

        var result: c.kuzu_query_result = std.mem.zeroes(c.kuzu_query_result);
        const state = c.kuzu_connection_query(&self.conn, c_query, &result);
        if (result._query_result == null) {
            if (state != c.KuzuSuccess) {
                self.setError(.query, "kuzu_connection_query failed");
            } else {
                self.setError(.query, "kuzu_connection_query returned no result");
            }
            return Error.QueryFailed;
        }

        var q = QueryResult.init(result, self.allocator);
        if (!q.isSuccess()) {
            const msg_opt = q.getErrorMessage() catch null;
            if (msg_opt) |owned| {
                self.setError(.query, owned);
                self.allocator.free(owned);
            } else {
                self.setError(.query, "");
            }
            q.deinit();
            return Error.QueryFailed;
        }

        if (state != c.KuzuSuccess) {
            q.deinit();
            self.setError(.query, "kuzu_connection_query failed");
            return Error.QueryFailed;
        }

        return q;
    }

    pub fn exec(self: *Conn, query_str: []const u8) !void {
        var q = try self.query(query_str);
        defer q.deinit();
    }

    pub fn prepare(self: *Conn, query_str: []const u8) !PreparedStatement {
        const Ps = prepared_statement.PreparedStatementType(@This());

        const c_query = try toCString(self.allocator, query_str);
        defer self.allocator.free(c_query);

        self.clearError();

        var stmt: c.kuzu_prepared_statement = std.mem.zeroes(c.kuzu_prepared_statement);
        const state = c.kuzu_connection_prepare(&self.conn, c_query, &stmt);
        if (stmt._prepared_statement == null or stmt._bound_values == null) {
            if (stmt._prepared_statement != null) {
                c.kuzu_prepared_statement_destroy(&stmt);
            }
            if (state != c.KuzuSuccess) {
                self.setError(.prepare, "kuzu_connection_prepare failed");
            } else {
                self.setError(.prepare, "kuzu_connection_prepare returned no statement");
            }
            return Error.PrepareFailed;
        }

        if (!c.kuzu_prepared_statement_is_success(&stmt)) {
            const err_msg_ptr = c.kuzu_prepared_statement_get_error_message(&stmt);
            if (err_msg_ptr != null) {
                const msg_slice = std.mem.span(err_msg_ptr);
                if (msg_slice.len > 0) {
                    // Set structured error then continue
                    self.setError(.prepare, msg_slice);
                } else {
                    self.setError(.prepare, "");
                }
                if (err_msg_ptr != null) c.kuzu_destroy_string(err_msg_ptr);
            }
            c.kuzu_prepared_statement_destroy(&stmt);
            return Error.PrepareFailed;
        }

        return Ps{
            .stmt = stmt,
            .conn = self,
            .allocator = self.allocator,
        };
    }

    pub fn beginTransaction(self: *Conn) !void {
        var r = try self.query("BEGIN TRANSACTION");
        r.deinit();
    }

    pub fn commit(self: *Conn) !void {
        var r = try self.query("COMMIT");
        r.deinit();
    }

    pub fn rollback(self: *Conn) !void {
        var r = try self.query("ROLLBACK");
        r.deinit();
    }

    pub fn setMaxThreads(self: *Conn, num_threads: u64) !void {
        self.clearError();
        const state = c.kuzu_connection_set_max_num_thread_for_exec(&self.conn, num_threads);
        try checkStateWith(state, self.makeStateHandler("kuzu_connection_set_max_num_thread_for_exec failed", Error.InvalidArgument));
    }

    pub fn getMaxThreads(self: *Conn) !u64 {
        self.clearError();
        var num_threads: u64 = undefined;
        const state = c.kuzu_connection_get_max_num_thread_for_exec(&self.conn, &num_threads);
        try checkStateWith(state, self.makeStateHandler("kuzu_connection_get_max_num_thread_for_exec failed", Error.InvalidArgument));
        return num_threads;
    }

    pub fn interrupt(self: *Conn) void {
        c.kuzu_connection_interrupt(&self.conn);
    }

    pub fn setTimeout(self: *Conn, timeout_ms: u64) !void {
        self.clearError();
        const state = c.kuzu_connection_set_query_timeout(&self.conn, timeout_ms);
        try checkStateWith(state, self.makeStateHandler("kuzu_connection_set_query_timeout failed", Error.InvalidArgument));
    }
};

pub const PreparedStatement = prepared_statement.PreparedStatementType(Conn);
