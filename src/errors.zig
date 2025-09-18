const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;

pub const Error = error{
    DatabaseInit,
    ConnectionInit,
    InvalidDatabase,
    InvalidConnection,
    QueryFailed,
    PrepareFailed,
    BindFailed,
    ExecuteFailed,
    NoMoreRows,
    InvalidColumn,
    TypeMismatch,
    ConversionError,
    TransactionFailed,
    TransactionAlreadyClosed,
    TransactionRollback,
    OutOfMemory,
    InvalidArgument,
    NotImplemented,
    Unknown,
};

pub const StateErrorHandler = struct {
    allocator: std.mem.Allocator,
    fetch_addr: ?usize = null,
    fetch: ?*const fn (addr: usize, allocator: std.mem.Allocator) Error!?[]u8 = null,
    sink_addr: ?usize = null,
    sink: ?*const fn (addr: usize, msg: []const u8) void = null,
    fallback_message: ?[]const u8 = null,
    result_error: Error = Error.Unknown,
};

pub fn checkState(state: c.kuzu_state) Error!void {
    return checkStateWith(state, null);
}

pub fn checkStateWith(state: c.kuzu_state, handler: ?StateErrorHandler) Error!void {
    if (state == c.KuzuSuccess) return;

    var result_error: Error = Error.Unknown;
    if (handler) |h| {
        result_error = h.result_error;
        var owned_message: ?[]u8 = null;

        if (h.fetch) |fetch_fn| {
            if (h.fetch_addr) |addr| {
                owned_message = fetch_fn(addr, h.allocator) catch null;
            }
        }

        if (h.sink) |sink_fn| {
            if (owned_message) |msg| {
                if (h.sink_addr) |addr| sink_fn(addr, msg);
            } else if (h.fallback_message) |fallback| {
                if (h.sink_addr) |addr| sink_fn(addr, fallback);
            }
        } else if (h.fallback_message != null and owned_message == null) {
            std.log.warn("Kuzu call failed: {s}", .{h.fallback_message.?});
        }

        if (owned_message) |msg| {
            h.allocator.free(msg);
        }
    }

    return result_error;
}
