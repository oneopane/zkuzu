const std = @import("std");
const bindings = @import("bindings.zig");
const errors = @import("errors.zig");
const strings = @import("strings.zig");
const query_result = @import("query_result.zig");

const c = bindings.c;
const Error = errors.Error;
const toCString = strings.toCString;
const QueryResult = query_result.QueryResult;

// Prepared statement handle
pub fn PreparedStatementType(comptime ConnType: type) type {
    return struct {
        stmt: c.kuzu_prepared_statement,
        conn: *ConnType,
        allocator: std.mem.Allocator,

        const StateCtx = struct {
            stmt: *c.kuzu_prepared_statement,
            conn: *ConnType,
        };

        fn messageSink(addr: usize, msg: []const u8) void {
            const conn_ptr = @as(*ConnType, @ptrFromInt(addr));
            // Bind-time errors
            conn_ptr.setError(.bind, msg);
        }

        fn fetchMessage(addr: usize, allocator: std.mem.Allocator) errors.Error!?[]u8 {
            const state_ctx = @as(*StateCtx, @ptrFromInt(addr));
            const msg_ptr = c.kuzu_prepared_statement_get_error_message(state_ctx.stmt);
            if (msg_ptr == null) return null;
            const msg_slice = std.mem.span(msg_ptr);
            defer c.kuzu_destroy_string(msg_ptr);
            return try allocator.dupe(u8, msg_slice);
        }

        fn handleState(self: *@This(), state: c.kuzu_state, fallback: []const u8, err: Error) Error!void {
            if (state == c.KuzuSuccess) return;
            var ctx = StateCtx{ .stmt = &self.stmt, .conn = self.conn };
            const handler = errors.StateErrorHandler{
                .allocator = self.allocator,
                .fetch_addr = @intFromPtr(&ctx),
                .fetch = fetchMessage,
                .sink_addr = @intFromPtr(self.conn),
                .sink = messageSink,
                .fallback_message = fallback,
                .result_error = err,
            };
            return errors.checkStateWith(state, handler);
        }

        pub fn deinit(self: *@This()) void {
            c.kuzu_prepared_statement_destroy(&self.stmt);
        }

        // Bind parameters (typed, direct API)
        pub fn bindBool(self: *@This(), param_name: []const u8, value: bool) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_bool(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_bool failed", Error.BindFailed);
        }

        pub fn bindInt(self: *@This(), param_name: []const u8, value: i64) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_int64(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_int64 failed", Error.BindFailed);
        }

        pub fn bindInt32(self: *@This(), param_name: []const u8, value: i32) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_int32(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_int32 failed", Error.BindFailed);
        }

        pub fn bindInt16(self: *@This(), param_name: []const u8, value: i16) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_int16(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_int16 failed", Error.BindFailed);
        }

        pub fn bindInt8(self: *@This(), param_name: []const u8, value: i8) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_int8(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_int8 failed", Error.BindFailed);
        }

        pub fn bindUInt64(self: *@This(), param_name: []const u8, value: u64) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_uint64(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_uint64 failed", Error.BindFailed);
        }

        pub fn bindUInt32(self: *@This(), param_name: []const u8, value: u32) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_uint32(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_uint32 failed", Error.BindFailed);
        }

        pub fn bindUInt16(self: *@This(), param_name: []const u8, value: u16) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_uint16(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_uint16 failed", Error.BindFailed);
        }

        pub fn bindUInt8(self: *@This(), param_name: []const u8, value: u8) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_uint8(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_uint8 failed", Error.BindFailed);
        }

        pub fn bindString(self: *@This(), param_name: []const u8, value: []const u8) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const c_value = try toCString(self.allocator, value);
            defer self.allocator.free(c_value);
            const state = c.kuzu_prepared_statement_bind_string(&self.stmt, c_name, c_value);
            try self.handleState(state, "kuzu_prepared_statement_bind_string failed", Error.BindFailed);
        }

        pub fn bindFloat(self: *@This(), param_name: []const u8, value: f64) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_double(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_double failed", Error.BindFailed);
        }

        pub fn bindDate(self: *@This(), param_name: []const u8, value: c.kuzu_date_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_date(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_date failed", Error.BindFailed);
        }

        pub fn bindTimestamp(self: *@This(), param_name: []const u8, value: c.kuzu_timestamp_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_timestamp(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_timestamp failed", Error.BindFailed);
        }

        pub fn bindTimestampNs(self: *@This(), param_name: []const u8, value: c.kuzu_timestamp_ns_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_timestamp_ns(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_timestamp_ns failed", Error.BindFailed);
        }

        pub fn bindTimestampMs(self: *@This(), param_name: []const u8, value: c.kuzu_timestamp_ms_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_timestamp_ms(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_timestamp_ms failed", Error.BindFailed);
        }

        pub fn bindTimestampSec(self: *@This(), param_name: []const u8, value: c.kuzu_timestamp_sec_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_timestamp_sec(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_timestamp_sec failed", Error.BindFailed);
        }

        pub fn bindTimestampTz(self: *@This(), param_name: []const u8, value: c.kuzu_timestamp_tz_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_timestamp_tz(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_timestamp_tz failed", Error.BindFailed);
        }

        pub fn bindInterval(self: *@This(), param_name: []const u8, value: c.kuzu_interval_t) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            const state = c.kuzu_prepared_statement_bind_interval(&self.stmt, c_name, value);
            try self.handleState(state, "kuzu_prepared_statement_bind_interval failed", Error.BindFailed);
        }

        pub fn bindNull(self: *@This(), param_name: []const u8, value_type: anytype) !void {
            const c_name = try toCString(self.allocator, param_name);
            defer self.allocator.free(c_name);
            // Create a NULL value with the given logical type
            const dt_id = @as(c.kuzu_data_type_id, @intCast(value_type));
            var dt: c.kuzu_logical_type = undefined;
            c.kuzu_data_type_create(dt_id, null, 0, &dt);
            defer c.kuzu_data_type_destroy(&dt);
            const val_ptr = c.kuzu_value_create_null_with_data_type(&dt);
            defer c.kuzu_value_destroy(val_ptr);
            const state = c.kuzu_prepared_statement_bind_value(&self.stmt, c_name, val_ptr);
            try self.handleState(state, "kuzu_prepared_statement_bind_value failed", Error.BindFailed);
        }

        // Execute prepared statement
        pub fn execute(self: *@This()) !QueryResult {
            self.conn.clearError();
            const prev = try self.conn.beginOp();
            var ok: bool = false;
            defer self.conn.endOp(prev, ok, null);

            var result: c.kuzu_query_result = std.mem.zeroes(c.kuzu_query_result);
            const state = c.kuzu_connection_execute(&self.conn.conn, &self.stmt, &result);
            if (result._query_result == null) {
                if (state != c.KuzuSuccess) {
                    self.conn.setError(.execute, "kuzu_connection_execute failed");
                } else {
                    self.conn.setError(.execute, "kuzu_connection_execute returned no result");
                }
                return Error.ExecuteFailed;
            }

            var q = QueryResult.init(result, self.allocator);
            if (!q.isSuccess()) {
                const msg_opt = q.getErrorMessage() catch null;
                if (msg_opt) |owned| {
                    self.conn.setError(.execute, owned);
                    self.allocator.free(owned);
                } else {
                    self.conn.setError(.execute, "");
                }
                q.deinit();
                return Error.ExecuteFailed;
            }

            if (state != c.KuzuSuccess) {
                q.deinit();
                self.conn.setError(.execute, "kuzu_connection_execute failed");
                return Error.ExecuteFailed;
            }

            ok = true;
            self.conn.stats.total_executes += 1;
            return q;
        }
    };
}
