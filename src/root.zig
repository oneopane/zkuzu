const std = @import("std");
const bindings = @import("bindings.zig");
const database = @import("database.zig");
const connection = @import("conn.zig");
const query_result = @import("query_result.zig");
const errors = @import("errors.zig");
const strings = @import("strings.zig");

pub const c = bindings.c;

pub const Database = database.Database;
pub const SystemConfig = database.SystemConfig;
pub const Conn = connection.Conn;
pub const ConnStats = connection.Conn.Stats;
pub const PreparedStatement = connection.PreparedStatement;
pub const QueryResult = query_result.QueryResult;
pub const Row = query_result.Row;
pub const Rows = query_result.Rows;
pub const Value = query_result.Value;
pub const ValueType = query_result.ValueType;
pub const QuerySummary = query_result.QuerySummary;

pub const Error = errors.Error;
pub const checkState = errors.checkState;
pub const toCString = strings.toCString;

pub const Pool = @import("pool.zig").Pool;

/// Open or create a database at `path` using an optional `SystemConfig`.
///
/// Convenience wrapper for `Database.init`.
///
/// Parameters:
/// - `path`: Zero-terminated filesystem path to the DB directory
/// - `config`: Optional system configuration
///
/// Returns: Initialized `Database` to `deinit()` when done
///
/// Errors:
/// - `Error.DatabaseInit`: If Kuzu initialization fails
pub fn open(path: [*:0]const u8, config: ?SystemConfig) !Database {
    return Database.init(path, config);
}

// Central test import to collect per-file tests under src/tests/
test "import all tests" {
    std.testing.refAllDecls(@import("tests/mod.zig"));
}
