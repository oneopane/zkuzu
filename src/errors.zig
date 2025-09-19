const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;

// High-level structured error for Kuzu operations.
// Captures operation context, coarse category, and owned message text.
pub const KuzuError = struct {
    pub const Op = enum {
        connect,
        query,
        prepare,
        execute,
        bind,
        config,
        transaction,
    };

    pub const Category = enum {
        argument,
        constraint,
        transaction,
        connection,
        timeout,
        interrupt,
        memory,
        unknown,
    };

    allocator: std.mem.Allocator,
    op: Op,
    category: Category = .unknown,
    message: []u8,
    detail: ?[]u8 = null,
    hint: ?[]u8 = null,
    code: ?[]const u8 = null,
    raw: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, op: Op, message: []const u8) !KuzuError {
        const msg_copy = try allocator.dupe(u8, message);
        var err = KuzuError{
            .allocator = allocator,
            .op = op,
            .category = .unknown,
            .message = msg_copy,
            .detail = null,
            .hint = null,
            .code = null,
            .raw = null,
        };
        err.categorize();
        return err;
    }

    pub fn deinit(self: *KuzuError) void {
        const a = self.allocator;
        a.free(self.message);
        if (self.detail) |d| a.free(d);
        if (self.hint) |h| a.free(h);
        if (self.raw) |r| a.free(r);
        self.* = undefined; // defensive: poison after free
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                const hc = std.ascii.toLower(haystack[i + j]);
                const nc = std.ascii.toLower(needle[j]);
                if (hc != nc) break;
            }
            if (j == needle.len) return true;
        }
        return false;
    }

    // Heuristic categorization from error message text.
    pub fn categorize(self: *KuzuError) void {
        const msg = self.message;
        // Common kuzu messages: "timeout", "interrupted", "Binder exception", "Parser error" etc.
        if (containsIgnoreCase(msg, "timeout") or containsIgnoreCase(msg, "timed out")) {
            self.category = .timeout;
            return;
        }
        if (containsIgnoreCase(msg, "interrupt")) {
            self.category = .interrupt;
            return;
        }
        if (containsIgnoreCase(msg, "out of memory") or containsIgnoreCase(msg, "oom") or containsIgnoreCase(msg, "std::bad_alloc")) {
            self.category = .memory;
            return;
        }
        if (containsIgnoreCase(msg, "constraint") or containsIgnoreCase(msg, "unique") or containsIgnoreCase(msg, "primary key") or containsIgnoreCase(msg, "foreign key")) {
            self.category = .constraint;
            return;
        }
        if (containsIgnoreCase(msg, "transaction") or containsIgnoreCase(msg, "rollback") or containsIgnoreCase(msg, "commit")) {
            self.category = .transaction;
            return;
        }
        if (containsIgnoreCase(msg, "connect") or containsIgnoreCase(msg, "connection")) {
            self.category = .connection;
            return;
        }
        if (containsIgnoreCase(msg, "parse") or containsIgnoreCase(msg, "parser") or containsIgnoreCase(msg, "syntax") or containsIgnoreCase(msg, "binder") or containsIgnoreCase(msg, "bind parameter") or containsIgnoreCase(msg, "invalid argument") or containsIgnoreCase(msg, "bad argument")) {
            self.category = .argument;
            return;
        }
        // Default
        self.category = .unknown;
    }
};

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
