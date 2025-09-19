const std = @import("std");
const bindings = @import("bindings.zig");
const errors = @import("errors.zig");

const c = bindings.c;
const valtypes = @import("value.zig");
const Error = errors.Error;
const checkState = errors.checkState;
const ArenaAllocator = std.heap.ArenaAllocator;

// Query result handle
pub const QueryResult = struct {
    result: c.kuzu_query_result,
    allocator: std.mem.Allocator,
    current_row: ?*Row = null,
    name_to_index: ?std.StringHashMapUnmanaged(u64) = null,
    _arena: *ArenaAllocator,

    /// Initialize a `QueryResult` wrapper around a Kuzu `kuzu_query_result`.
    ///
    /// Parameters:
    /// - `result`: Raw C handle returned by Kuzu
    /// - `allocator`: Allocator used for row/value lifetimes and maps
    ///
    /// Returns: A `QueryResult` value; call `deinit()` when finished.
    pub fn init(result: c.kuzu_query_result, allocator: std.mem.Allocator) QueryResult {
        const arena = allocator.create(ArenaAllocator) catch @panic("arena alloc failed");
        arena.* = ArenaAllocator.init(allocator);
        return .{
            .result = result,
            .allocator = allocator,
            ._arena = arena,
        };
    }

    /// Destroy the query result and free owned resources.
    ///
    /// Releases any active row, internal maps, and the arena used for strings.
    pub fn deinit(self: *QueryResult) void {
        // Clean up any current row tuple first
        if (self.current_row) |row| {
            row.deinit();
            self.current_row = null;
        }
        if (self.name_to_index) |*m| {
            // Keys are arena-allocated; only free the map storage itself
            m.deinit(self.allocator);
            self.name_to_index = null;
        }
        c.kuzu_query_result_destroy(&self.result);
        // Release arena last so any borrowed strings remain valid until now
        const arena = self._arena;
        arena.deinit();
        self.allocator.destroy(arena);
    }

    // Check if query was successful
    /// Whether the underlying Kuzu execution succeeded.
    ///
    /// Returns: `true` on success; `false` if Kuzu reported an error
    pub fn isSuccess(self: *QueryResult) bool {
        return c.kuzu_query_result_is_success(&self.result);
    }

    /// Get an owned copy of the error message if the query failed.
    ///
    /// Returns: `?[]u8` owned by `self.allocator` or `null` if none.
    ///
    /// Errors:
    /// - `error.OutOfMemory`: If duplicating the message fails
    pub fn getErrorMessage(self: *QueryResult) !?[]u8 {
        const msg_ptr = c.kuzu_query_result_get_error_message(&self.result);
        if (msg_ptr == null) return null;
        const msg_slice = std.mem.span(msg_ptr);
        // Keep error message owned by the connection allocator (not arena),
        // since caller may store it beyond this result's lifetime.
        const copy = try self.allocator.dupe(u8, msg_slice);
        c.kuzu_destroy_string(msg_ptr);
        return copy;
    }

    /// Get number of columns in the result schema.
    ///
    /// Returns: Column count as `u64`
    pub fn getColumnCount(self: *QueryResult) u64 {
        return c.kuzu_query_result_get_num_columns(&self.result);
    }

    /// Get column name by index.
    ///
    /// Parameters:
    /// - `index`: Zero-based column index
    ///
    /// Returns: Borrowed string stored in this result's arena
    ///
    /// Errors:
    /// - `Error.Unknown`: If the C call fails
    pub fn getColumnName(self: *QueryResult, index: u64) ![]const u8 {
        var name_ptr: [*c]u8 = undefined;
        const state = c.kuzu_query_result_get_column_name(&self.result, index, &name_ptr);
        try checkState(state);
        if (name_ptr == null) return "";
        const name_slice = std.mem.span(name_ptr);
        const copy = try self._arena.allocator().dupe(u8, name_slice);
        c.kuzu_destroy_string(name_ptr);
        return copy;
    }

    fn ensureNameIndexCache(self: *QueryResult) !void {
        if (self.name_to_index != null) return;
        var map: std.StringHashMapUnmanaged(u64) = .{};
        errdefer map.deinit(self.allocator);
        const n = self.getColumnCount();
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const name = try self.getColumnName(i);
            // Column names are arena-owned; map stores pointer only.
            try map.put(self.allocator, name, i);
        }
        self.name_to_index = map;
    }

    /// Look up column index by name (O(1) after first call).
    ///
    /// Parameters:
    /// - `name`: Column name
    ///
    /// Returns: `?u64` index if found; otherwise `null`
    ///
    /// Errors:
    /// - `error.OutOfMemory`: If the name map must be allocated and fails
    pub fn getColumnIndex(self: *QueryResult, name: []const u8) !?u64 {
        try self.ensureNameIndexCache();
        const map = &self.name_to_index.?;
        return map.get(name);
    }

    /// Get logical data type id for the column at `index`.
    ///
    /// Returns: `ValueType` corresponding to Kuzu logical type id
    ///
    /// Errors:
    /// - `Error.Unknown`: If the C call fails
    pub fn getColumnDataType(self: *QueryResult, index: u64) !ValueType {
        var dtype: c.kuzu_logical_type = undefined;
        const state = c.kuzu_query_result_get_column_data_type(&self.result, index, &dtype);
        try checkState(state);
        defer c.kuzu_data_type_destroy(&dtype);
        const type_id = c.kuzu_data_type_get_id(&dtype);
        return @as(ValueType, @enumFromInt(type_id));
    }

    /// Whether there are more rows to iterate.
    ///
    /// Returns: `true` if `next()` may yield a row
    pub fn hasNext(self: *QueryResult) bool {
        return c.kuzu_query_result_has_next(&self.result);
    }

    /// Fetch the next row as a `*Row` handle.
    ///
    /// Returns: `?*Row`. Caller must `deinit()` the row before calling `next()` again.
    ///
    /// Errors:
    /// - `Error.Unknown`: If Kuzu returns a failing state
    /// - `error.OutOfMemory`: If allocation fails
    ///
    /// Example:
    /// ```zig
    /// while (try qr.next()) |row| { defer row.deinit(); }
    /// ```
    pub fn next(self: *QueryResult) !?*Row {
        if (!self.hasNext()) {
            return null;
        }

        var flat_tuple: c.kuzu_flat_tuple = undefined;
        const state = c.kuzu_query_result_get_next(&self.result, &flat_tuple);
        try checkState(state);
        errdefer c.kuzu_flat_tuple_destroy(&flat_tuple);

        // Destroy the previous row (tuple) if the caller didn't already
        if (self.current_row) |row| {
            row.deinit();
            self.current_row = null;
        }

        const row_ptr = try self.allocator.create(Row);
        errdefer self.allocator.destroy(row_ptr);
        row_ptr.* = Row.init(flat_tuple, self, self.allocator);
        self.current_row = row_ptr;
        return row_ptr;
    }

    /// Reset the row iterator to the beginning.
    pub fn reset(self: *QueryResult) void {
        if (self.current_row) |row| {
            row.deinit();
            self.current_row = null;
        }
        c.kuzu_query_result_reset_iterator(&self.result);
    }

    /// Get compile and execution time summary for the query.
    ///
    /// Returns: `QuerySummary` with times in milliseconds
    ///
    /// Errors:
    /// - `Error.Unknown`: If the C call fails
    pub fn getSummary(self: *QueryResult) !QuerySummary {
        var summary: c.kuzu_query_summary = undefined;
        const state = c.kuzu_query_result_get_query_summary(&self.result, &summary);
        try checkState(state);
        defer c.kuzu_query_summary_destroy(&summary);

        const compiling_time = c.kuzu_query_summary_get_compiling_time(&summary);
        const execution_time = c.kuzu_query_summary_get_execution_time(&summary);

        return QuerySummary{
            .compiling_time_ms = compiling_time,
            .execution_time_ms = execution_time,
        };
    }
};

// Row in query result
pub const Row = struct {
    tuple: c.kuzu_flat_tuple,
    result: *QueryResult,
    allocator: std.mem.Allocator,
    owned_blobs: std.ArrayListUnmanaged([*c]u8) = .{},
    is_active: bool = true,

    /// Initialize a `Row` wrapper around a `kuzu_flat_tuple`.
    ///
    /// Parameters:
    /// - `tuple`: Raw C tuple handle for the current row
    /// - `result`: Parent `QueryResult` (for arena and column lookups)
    /// - `allocator`: Allocator used for owned values/blobs
    ///
    /// Returns: Initialized `Row`; call `deinit()` when done with the row.
    pub fn init(tuple: c.kuzu_flat_tuple, result: *QueryResult, allocator: std.mem.Allocator) Row {
        return .{
            .tuple = tuple,
            .result = result,
            .allocator = allocator,
            .owned_blobs = .{},
            .is_active = true,
        };
    }

    /// Destroy the row, releasing the underlying C tuple and owned blobs.
    ///
    /// Safe to call once. After `deinit`, the handle is inactive.
    pub fn deinit(self: *Row) void {
        if (!self.is_active) return;
        self.is_active = false;

        // Free any C-allocated blobs obtained from this row (strings go to arena)
        for (self.owned_blobs.items) |ptr| {
            if (ptr != null) c.kuzu_destroy_blob(@ptrCast(ptr));
        }
        self.owned_blobs.deinit(self.allocator);
        c.kuzu_flat_tuple_destroy(&self.tuple);

        if (self.result.current_row) |row_ptr| {
            if (row_ptr == self) {
                self.result.current_row = null;
            }
        }

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Get a generic `Value` at the given column `index`.
    ///
    /// Returns: Owned `Value` that must be `deinit()`ed by the caller.
    ///
    /// Errors:
    /// - `Error.Unknown`: If the C call fails
    pub fn getValue(self: *Row, index: u64) !Value {
        var val: c.kuzu_value = undefined;
        const state = c.kuzu_flat_tuple_get_value(&self.tuple, index, &val);
        try checkState(state);
        var v = Value.fromCValue(val, self.allocator);
        v.owned = true; // values fetched from FlatTuple must be destroyed
        v.owner_row = self;
        return v;
    }

    /// Type-safe generic getter with compile-time validation and null handling.
    ///
    /// Parameters:
    /// - `T`: Destination type (e.g. `i64`, `?[]const u8`, `[]Value`, `Value`)
    /// - `index`: Zero-based column index
    ///
    /// Returns: A value of type `T` converted from the Kuzu value.
    ///
    /// Errors:
    /// - `Error.TypeMismatch`: If the logical type cannot convert to `T`
    /// - `Error.InvalidArgument`: If the value is NULL but `T` is not optional
    /// - `error.OutOfMemory`: On allocation for slices/strings
    ///
    /// Example:
    /// ```zig
    /// const name: []const u8 = try row.get([]const u8, 0);
    /// const maybe_age: ?i64 = try row.get(?i64, 1);
    /// ```
    pub fn get(self: *Row, comptime T: type, index: usize) !T {
        const is_array = comptime valtypes.TypeInfo.isArray(T);
        // Disallow fixed-size arrays; support slices instead.
        if (is_array) {
            @compileError("Row.get: fixed-size arrays not supported; use a slice type instead");
        }

        // Fetch once from the tuple; `Value` is owned and tied to this row.
        var v = try self.getValue(@intCast(index));
        const is_opt = comptime valtypes.TypeInfo.isOptional(T);
        if (v.isNull()) {
            if (is_opt) {
                v.deinit();
                return null;
            } else {
                v.deinit();
                return Error.InvalidArgument;
            }
        }

        // Convert and free the temporary value unless returning it directly.
        const result = try self._convertValue(T, &v);
        // If returning Value itself (or optional Value already handled above), do not deinit.
        const return_is_value = comptime (T == Value or (is_opt and valtypes.TypeInfo.childOfOptional(T) == Value));
        if (!return_is_value) {
            v.deinit();
        }
        return result;
    }

    /// Generic get by column name using cached name→index mapping.
    ///
    /// Parameters:
    /// - `T`: Destination type
    /// - `name`: Column name to resolve
    ///
    /// Returns: Value of type `T` or error
    pub fn getByName(self: *Row, comptime T: type, name: []const u8) !T {
        const idx = (try self.result.getColumnIndex(name)) orelse return Error.InvalidColumn;
        return try self.get(T, idx);
    }

    fn _convertValue(self: *Row, comptime T: type, val: *Value) !T {
        const A = self.result._arena.allocator();
        const is_optional = comptime valtypes.TypeInfo.isOptional(T);
        const is_bool = comptime valtypes.TypeInfo.isBool(T);
        const is_signed = comptime valtypes.TypeInfo.isSignedInt(T);
        const is_unsigned = comptime valtypes.TypeInfo.isUnsignedInt(T);
        const is_float = comptime valtypes.TypeInfo.isFloat(T);
        const is_string_like = comptime valtypes.TypeInfo.isStringLike(T);
        const is_slice = comptime valtypes.TypeInfo.isSlice(T);

        // Optional handling: unwrap, but call-site already checked for nulls.
        if (is_optional) {
            const Child = valtypes.TypeInfo.childOfOptional(T);
            const inner: Child = try self._convertValue(Child, val);
            return @as(T, inner);
        }

        // Direct pass-through for Value
        if (T == Value) {
            // Return a copy of the handle by value. Caller is responsible to deinit.
            return val.*;
        }

        // Scalars
        if (is_bool) {
            return try val.toBool();
        }
        if (is_signed) {
            const x = try val.toInt();
            return try @import("value.zig").Cast.toInt(T, x);
        }
        if (is_unsigned) {
            const x = try val.toUInt();
            return try @import("value.zig").Cast.toInt(T, x);
        }
        if (is_float) {
            const x = try val.toFloat();
            return try @import("value.zig").Cast.toFloat(T, x);
        }
        if (is_string_like) {
            // Disambiguate by actual Kuzu logical type.
            const vt = val.getType();
            return switch (vt) {
                .String => try val.toString(),
                .Blob => try val.toBlob(),
                .Uuid => try val.toUuid(),
                .Decimal => try val.toDecimalString(),
                else => Error.TypeMismatch,
            };
        }

        // Slices (Lists/Arrays): []Child
        if (is_slice) {
            const Elem = valtypes.TypeInfo.sliceChild(T);
            const vt = val.getType();
            if (vt != .List and vt != .Array and vt != .Map) return Error.TypeMismatch;

            if (vt == .Map) {
                // Expect slice of struct { key: K, value: V }
                const ti = @typeInfo(Elem);
                if (ti != .@"struct") return Error.TypeMismatch;
                const fields = ti.@"struct".fields;
                if (fields.len != 2 or !std.mem.eql(u8, fields[0].name, "key") or !std.mem.eql(u8, fields[1].name, "value")) {
                    return Error.TypeMismatch;
                }
                const K = fields[0].type;
                const V = fields[1].type;
                const size = try val.getMapSize();
                var out = try A.alloc(Elem, @intCast(size));
                var i: u64 = 0;
                while (i < size) : (i += 1) {
                    var k_raw = try val.getMapKey(i);
                    defer k_raw.deinit();
                    var v_raw = try val.getMapValue(i);
                    defer v_raw.deinit();
                    var item: Elem = undefined;
                    @field(item, "key") = try self._convertValue(K, &k_raw);
                    @field(item, "value") = try self._convertValue(V, &v_raw);
                    out[@intCast(i)] = item;
                }
                return out;
            }

            const len = try val.getListLength();
            var out = try A.alloc(Elem, @intCast(len));
            var i: u64 = 0;
            while (i < len) : (i += 1) {
                var child = try val.getListElement(i);
                defer child.deinit();
                out[@intCast(i)] = try self._convertValue(Elem, &child);
            }
            return out;
        }

        // Struct mapping: Zig struct field names must match Kuzu struct field names
        const ti = @typeInfo(T);
        if (ti == .@"struct") {
            const vt = val.getType();
            switch (vt) {
                .Struct, .Union, .Node, .Rel, .RecursiveRel => {},
                else => return Error.TypeMismatch,
            }
            var result: T = undefined;
            inline for (ti.@"struct".fields) |f| {
                const kuzu_n = try val.getStructFieldCount();
                var j: u64 = 0;
                var found = false;
                while (j < kuzu_n) : (j += 1) {
                    const name = try val.getStructFieldName(j);
                    if (std.mem.eql(u8, name, f.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return Error.TypeMismatch;
                var child_val = try val.getStructFieldValue(j);
                defer child_val.deinit();
                @field(result, f.name) = try self._convertValue(f.type, &child_val);
            }
            return result;
        }

        @compileError(std.fmt.comptimePrint("Row.get: unsupported target type {s}", .{@typeName(T)}));
    }

    // Convenience methods for common types
    /// Get a boolean at `index`.
    ///
    /// Errors: `Error.TypeMismatch` if the value is not Bool
    pub fn getBool(self: *Row, index: u64) !bool {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toBool();
    }

    /// Get a signed 64-bit integer at `index`.
    ///
    /// Errors: `Error.TypeMismatch` if the value is not an int
    pub fn getInt(self: *Row, index: u64) !i64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toInt();
    }

    /// Get a double-precision float at `index`.
    pub fn getFloat(self: *Row, index: u64) !f64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toFloat();
    }

    /// Get an unsigned 64-bit integer at `index`.
    pub fn getUInt(self: *Row, index: u64) !u64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toUInt();
    }

    /// Get a borrowed UTF-8 slice at `index` valid until `row.deinit()`.
    ///
    /// Errors: `Error.Unknown` on C call failures
    pub fn getString(self: *Row, index: u64) ![]const u8 {
        // Fetch as C string and tie lifetime to this row
        var val: c.kuzu_value = undefined;
        const state = c.kuzu_flat_tuple_get_value(&self.tuple, index, &val);
        try checkState(state);
        defer c.kuzu_value_destroy(&val);
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_string(&val, &c_str));
        if (c_str == null) return "";
        const slice = std.mem.span(c_str);
        const out = try self.result._arena.allocator().dupe(u8, slice);
        c.kuzu_destroy_string(c_str);
        return out;
    }

    /// Copy the string at `index` using `allocator`. Returns null if value is NULL.
    pub fn copyString(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const s = try self.getString(index);
        return try allocator.dupe(u8, s);
    }

    /// Convenience: `getInt` by column `name`.
    pub fn getIntByName(self: *Row, name: []const u8) !i64 {
        const idx = (try self.result.getColumnIndex(name)) orelse return Error.InvalidColumn;
        return try self.getInt(idx);
    }

    /// Convenience: `getString` by column `name`.
    pub fn getStringByName(self: *Row, name: []const u8) ![]const u8 {
        const idx = (try self.result.getColumnIndex(name)) orelse return Error.InvalidColumn;
        return try self.getString(idx);
    }

    /// Whether the value at `index` is NULL.
    pub fn isNull(self: *Row, index: u64) !bool {
        var val: c.kuzu_value = undefined;
        const state = c.kuzu_flat_tuple_get_value(&self.tuple, index, &val);
        try checkState(state);
        defer c.kuzu_value_destroy(&val);
        return c.kuzu_value_is_null(&val);
    }

    // Extended typed getters
    /// Get a borrowed blob at `index` valid until `row.deinit()`.
    pub fn getBlob(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toBlob();
    }

    /// Copy the blob at `index` using `allocator`. Returns null if value is NULL.
    pub fn copyBlob(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const b = try self.getBlob(index);
        return try allocator.dupe(u8, b);
    }

    /// Get a `kuzu_date_t` at `index`.
    pub fn getDate(self: *Row, index: u64) !c.kuzu_date_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toDate();
    }

    /// Get a `kuzu_timestamp_t` at `index`.
    pub fn getTimestamp(self: *Row, index: u64) !c.kuzu_timestamp_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toTimestamp();
    }

    /// Get a `kuzu_interval_t` at `index`.
    pub fn getInterval(self: *Row, index: u64) !c.kuzu_interval_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toInterval();
    }

    /// Get a UUID string at `index`.
    pub fn getUuid(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toUuid();
    }

    /// Copy the UUID string at `index`; returns null if NULL.
    pub fn copyUuid(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const u = try self.getUuid(index);
        return try allocator.dupe(u8, u);
    }

    /// Get a decimal value rendered as string at `index`.
    pub fn getDecimalString(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toDecimalString();
    }

    /// Copy the decimal string at `index`; returns null if NULL.
    pub fn copyDecimalString(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const s = try self.getDecimalString(index);
        return try allocator.dupe(u8, s);
    }

    /// Get an internal id struct at `index`.
    pub fn getInternalId(self: *Row, index: u64) !c.kuzu_internal_id_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toInternalId();
    }
};

// Represents result iterator
pub const Rows = struct {
    result: *QueryResult,

    /// Fetch the next row via the underlying `QueryResult`.
    ///
    /// Returns: `?*Row` or error; caller must `deinit()` the row.
    pub fn next(self: *Rows) !?*Row {
        return self.result.next();
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *Rows) void {
        self.result.reset();
    }
};

// Value types
pub const ValueType = enum(u32) {
    Any = 0,
    Node = 10,
    Rel = 11,
    RecursiveRel = 12,
    Serial = 13,
    Bool = 22,
    Int64 = 23,
    Int32 = 24,
    Int16 = 25,
    Int8 = 26,
    UInt64 = 27,
    UInt32 = 28,
    UInt16 = 29,
    UInt8 = 30,
    Int128 = 31,
    Double = 32,
    Float = 33,
    Date = 34,
    Timestamp = 35,
    TimestampSec = 36,
    TimestampMs = 37,
    TimestampNs = 38,
    TimestampTz = 39,
    Interval = 40,
    Decimal = 41,
    InternalId = 42,
    String = 50,
    Blob = 51,
    List = 52,
    Array = 53,
    Struct = 54,
    Map = 55,
    Union = 56,
    Pointer = 58,
    Uuid = 59,
};

// Value wrapper
pub const Value = struct {
    value: c.kuzu_value,
    allocator: std.mem.Allocator,
    owned: bool,
    owner_row: ?*Row = null,

    /// Wrap a raw `kuzu_value` in a `Value` (not owned by default).
    ///
    /// Parameters:
    /// - `val`: Raw C value handle
    /// - `allocator`: Allocator used for copied strings/blobs
    ///
    /// Returns: A `Value` with `owned=false`. Callers may set ownership.
    pub fn fromCValue(val: c.kuzu_value, allocator: std.mem.Allocator) Value {
        return .{
            .value = val,
            .allocator = allocator,
            .owned = false,
        };
    }

    /// Destroy the value if owned.
    ///
    /// Safe to call even if not owned; no-op in that case.
    pub fn deinit(self: *Value) void {
        if (self.owned) c.kuzu_value_destroy(&self.value);
    }

    fn makeOwnedChild(self: *Value, child_raw: c.kuzu_value) Value {
        var child = Value.fromCValue(child_raw, self.allocator);
        child.owned = true;
        child.owner_row = self.owner_row;
        return child;
    }

    fn borrowCString(self: *Value, c_str: [*c]u8) ![]const u8 {
        if (c_str == null) return "";
        const slice = std.mem.span(c_str);
        if (self.owner_row) |row| {
            const out = try row.result._arena.allocator().dupe(u8, slice);
            c.kuzu_destroy_string(c_str);
            return out;
        }
        const copy = try self.allocator.dupe(u8, slice);
        c.kuzu_destroy_string(c_str);
        return copy;
    }

    fn copyCString(self: *Value, allocator: std.mem.Allocator, c_str: [*c]u8) ![]u8 {
        _ = self;
        if (c_str == null) return try allocator.alloc(u8, 0);
        const slice = std.mem.span(c_str);
        defer c.kuzu_destroy_string(c_str);
        return try allocator.dupe(u8, slice);
    }

    /// Get the logical type of this value.
    ///
    /// Returns: `ValueType` enum
    pub fn getType(self: *Value) ValueType {
        var dtype: c.kuzu_logical_type = undefined;
        c.kuzu_value_get_data_type(&self.value, &dtype);
        defer c.kuzu_data_type_destroy(&dtype);
        const type_id = c.kuzu_data_type_get_id(&dtype);
        return @as(ValueType, @enumFromInt(type_id));
    }

    /// Whether this value is NULL.
    pub fn isNull(self: *Value) bool {
        return c.kuzu_value_is_null(&self.value);
    }

    /// Convert to bool.
    ///
    /// Errors: `Error.TypeMismatch` if underlying type is not Bool
    pub fn toBool(self: *Value) !bool {
        if (self.getType() != .Bool) return Error.TypeMismatch;
        var result: bool = undefined;
        const state = c.kuzu_value_get_bool(&self.value, &result);
        try checkState(state);
        return result;
    }

    /// Convert to signed 64-bit integer from Int8/16/32/64.
    ///
    /// Errors: `Error.TypeMismatch` if type is not a signed integer
    pub fn toInt(self: *Value) !i64 {
        const value_type = self.getType();
        switch (value_type) {
            .Int64 => {
                var result: i64 = undefined;
                const state = c.kuzu_value_get_int64(&self.value, &result);
                try checkState(state);
                return result;
            },
            .Int32 => {
                var result: i32 = undefined;
                const state = c.kuzu_value_get_int32(&self.value, &result);
                try checkState(state);
                return @as(i64, result);
            },
            .Int16 => {
                var result: i16 = undefined;
                const state = c.kuzu_value_get_int16(&self.value, &result);
                try checkState(state);
                return @as(i64, result);
            },
            .Int8 => {
                var result: i8 = undefined;
                const state = c.kuzu_value_get_int8(&self.value, &result);
                try checkState(state);
                return @as(i64, result);
            },
            else => return Error.TypeMismatch,
        }
    }

    /// Convert to unsigned 64-bit integer from UInt8/16/32/64.
    ///
    /// Errors: `Error.TypeMismatch` if type is not an unsigned integer
    pub fn toUInt(self: *Value) !u64 {
        const value_type = self.getType();
        switch (value_type) {
            .UInt64 => {
                var result: u64 = undefined;
                try checkState(c.kuzu_value_get_uint64(&self.value, &result));
                return result;
            },
            .UInt32 => {
                var result: u32 = undefined;
                try checkState(c.kuzu_value_get_uint32(&self.value, &result));
                return @as(u64, result);
            },
            .UInt16 => {
                var result: u16 = undefined;
                try checkState(c.kuzu_value_get_uint16(&self.value, &result));
                return @as(u64, result);
            },
            .UInt8 => {
                var result: u8 = undefined;
                try checkState(c.kuzu_value_get_uint8(&self.value, &result));
                return @as(u64, result);
            },
            else => return Error.TypeMismatch,
        }
    }

    /// Convert to double-precision float.
    ///
    /// Errors: `Error.TypeMismatch` if not Float/Double
    pub fn toFloat(self: *Value) !f64 {
        const value_type = self.getType();
        switch (value_type) {
            .Double => {
                var result: f64 = undefined;
                const state = c.kuzu_value_get_double(&self.value, &result);
                try checkState(state);
                return result;
            },
            .Float => {
                var result: f32 = undefined;
                const state = c.kuzu_value_get_float(&self.value, &result);
                try checkState(state);
                return @as(f64, result);
            },
            else => return Error.TypeMismatch,
        }
    }

    /// Convert to `kuzu_date_t`.
    pub fn toDate(self: *Value) !c.kuzu_date_t {
        if (self.getType() != .Date) return Error.TypeMismatch;
        var d: c.kuzu_date_t = undefined;
        try checkState(c.kuzu_value_get_date(&self.value, &d));
        return d;
    }

    /// Convert to `kuzu_timestamp_t`.
    pub fn toTimestamp(self: *Value) !c.kuzu_timestamp_t {
        const t = self.getType();
        var ts: c.kuzu_timestamp_t = undefined;
        switch (t) {
            .Timestamp => try checkState(c.kuzu_value_get_timestamp(&self.value, &ts)),
            .TimestampNs => {
                var tmp: c.kuzu_timestamp_ns_t = undefined;
                try checkState(c.kuzu_value_get_timestamp_ns(&self.value, &tmp));
                ts.value = tmp.value;
            },
            .TimestampMs => {
                var tmp: c.kuzu_timestamp_ms_t = undefined;
                try checkState(c.kuzu_value_get_timestamp_ms(&self.value, &tmp));
                ts.value = tmp.value;
            },
            .TimestampSec => {
                var tmp: c.kuzu_timestamp_sec_t = undefined;
                try checkState(c.kuzu_value_get_timestamp_sec(&self.value, &tmp));
                ts.value = tmp.value;
            },
            else => return Error.TypeMismatch,
        }
        return ts;
    }

    /// Convert to `kuzu_interval_t`.
    pub fn toInterval(self: *Value) !c.kuzu_interval_t {
        if (self.getType() != .Interval) return Error.TypeMismatch;
        var i: c.kuzu_interval_t = undefined;
        try checkState(c.kuzu_value_get_interval(&self.value, &i));
        return i;
    }

    /// Convert to UUID as a borrowed string.
    pub fn toUuid(self: *Value) ![]const u8 {
        if (self.getType() != .Uuid) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_uuid(&self.value, &c_str));
        return self.borrowCString(c_str);
    }

    /// Convert to decimal, rendered as a borrowed string.
    pub fn toDecimalString(self: *Value) ![]const u8 {
        if (self.getType() != .Decimal) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_decimal_as_string(&self.value, &c_str));
        return self.borrowCString(c_str);
    }

    /// Convert to `kuzu_internal_id_t`.
    pub fn toInternalId(self: *Value) !c.kuzu_internal_id_t {
        if (self.getType() != .InternalId) return Error.TypeMismatch;
        var id: c.kuzu_internal_id_t = undefined;
        try checkState(c.kuzu_value_get_internal_id(&self.value, &id));
        return id;
    }

    /// Convert to string as a borrowed slice.
    pub fn toString(self: *Value) ![]const u8 {
        if (self.getType() != .String) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        const state = c.kuzu_value_get_string(&self.value, &c_str);
        try checkState(state);
        return self.borrowCString(c_str);
    }

    /// Convert to blob as a borrowed slice.
    pub fn toBlob(self: *Value) ![]const u8 {
        if (self.getType() != .Blob) return Error.TypeMismatch;
        var blob_ptr: [*c]u8 = undefined;
        const state = c.kuzu_value_get_blob(&self.value, &blob_ptr);
        try checkState(state);
        if (blob_ptr == null) return "";
        if (self.owner_row) |row| {
            errdefer c.kuzu_destroy_blob(@ptrCast(blob_ptr));
            _ = try row.owned_blobs.append(row.allocator, blob_ptr);
        }
        // Blob is null-terminated per API docs
        return std.mem.span(blob_ptr);
    }

    /// Length of LIST/ARRAY value.
    ///
    /// Errors: `Error.TypeMismatch` if not list/array
    pub fn getListLength(self: *Value) !u64 {
        const t = self.getType();
        if (t != .List and t != .Array) return Error.TypeMismatch;
        var size: u64 = 0;
        try checkState(c.kuzu_value_get_list_size(&self.value, &size));
        return size;
    }

    /// Get the element `index` from LIST/ARRAY as an owned `Value`.
    pub fn getListElement(self: *Value, index: u64) !Value {
        const t = self.getType();
        if (t != .List and t != .Array) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_list_element(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// Number of fields on STRUCT/UNION/NODE/REL value.
    pub fn getStructFieldCount(self: *Value) !u64 {
        const t = self.getType();
        switch (t) {
            .Struct, .Union, .Node, .Rel, .RecursiveRel => {},
            else => return Error.TypeMismatch,
        }
        var count: u64 = 0;
        try checkState(c.kuzu_value_get_struct_num_fields(&self.value, &count));
        return count;
    }

    /// Get borrowed field name at `index` for STRUCT/UNION/NODE/REL.
    pub fn getStructFieldName(self: *Value, index: u64) ![]const u8 {
        const t = self.getType();
        switch (t) {
            .Struct, .Union, .Node, .Rel, .RecursiveRel => {},
            else => return Error.TypeMismatch,
        }
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_struct_field_name(&self.value, index, &c_str));
        return self.borrowCString(c_str);
    }

    /// Copy field name at `index` using `allocator`.
    pub fn copyStructFieldName(self: *Value, allocator: std.mem.Allocator, index: u64) ![]u8 {
        const t = self.getType();
        switch (t) {
            .Struct, .Union, .Node, .Rel, .RecursiveRel => {},
            else => return Error.TypeMismatch,
        }
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_struct_field_name(&self.value, index, &c_str));
        return self.copyCString(allocator, c_str);
    }

    /// Get field value at `index` as an owned `Value`.
    pub fn getStructFieldValue(self: *Value, index: u64) !Value {
        const t = self.getType();
        switch (t) {
            .Struct, .Union, .Node, .Rel, .RecursiveRel => {},
            else => return Error.TypeMismatch,
        }
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_struct_field_value(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// Number of entries in MAP value.
    pub fn getMapSize(self: *Value) !u64 {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var size: u64 = 0;
        try checkState(c.kuzu_value_get_map_size(&self.value, &size));
        return size;
    }

    /// Get map key at `index` as an owned `Value`.
    pub fn getMapKey(self: *Value, index: u64) !Value {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_map_key(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// Get map value at `index` as an owned `Value`.
    pub fn getMapValue(self: *Value, index: u64) !Value {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_map_value(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// Get the node list of a `RecursiveRel` as a `Value`.
    pub fn getRecursiveRelNodeList(self: *Value) !Value {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_recursive_rel_node_list(&self.value, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// Get the rel list of a `RecursiveRel` as a `Value`.
    pub fn getRecursiveRelRelList(self: *Value) !Value {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_recursive_rel_rel_list(&self.value, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    /// View this value as a `Node` helper.
    pub fn asNode(self: *Value) !Node {
        if (self.getType() != .Node) return Error.TypeMismatch;
        return Node{ .value = self };
    }

    /// View this value as a `Rel` helper.
    pub fn asRel(self: *Value) !Rel {
        if (self.getType() != .Rel) return Error.TypeMismatch;
        return Rel{ .value = self };
    }

    /// View this value as a `RecursiveRel` helper.
    pub fn asRecursiveRel(self: *Value) !RecursiveRel {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        return RecursiveRel{ .value = self };
    }

    pub const Node = struct {
        value: *Value,

        /// Get the node id as an owned `Value`.
        pub fn idValue(self: Node) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Get the node label as an owned `Value`.
        pub fn labelValue(self: Node) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_label_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Number of properties on this node.
        pub fn propertyCount(self: Node) !u64 {
            var size: u64 = 0;
            try checkState(c.kuzu_node_val_get_property_size(&self.value.value, &size));
            return size;
        }

        /// Borrowed property name at `index`.
        pub fn propertyName(self: Node, index: u64) ![]const u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_node_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.borrowCString(c_str);
        }

        /// Copy property name at `index` using `allocator`.
        pub fn copyPropertyName(self: Node, allocator: std.mem.Allocator, index: u64) ![]u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_node_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.copyCString(allocator, c_str);
        }

        /// Property value at `index` as an owned `Value`.
        pub fn propertyValue(self: Node, index: u64) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_property_value_at(&self.value.value, index, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }
    };

    pub const Rel = struct {
        value: *Value,

        /// Get the relationship id as an owned `Value`.
        pub fn idValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Get the src node id as an owned `Value`.
        pub fn srcIdValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_src_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Get the dst node id as an owned `Value`.
        pub fn dstIdValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_dst_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Get the label as an owned `Value`.
        pub fn labelValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_label_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        /// Number of properties on this relationship.
        pub fn propertyCount(self: Rel) !u64 {
            var size: u64 = 0;
            try checkState(c.kuzu_rel_val_get_property_size(&self.value.value, &size));
            return size;
        }

        /// Borrowed property name at `index`.
        pub fn propertyName(self: Rel, index: u64) ![]const u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_rel_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.borrowCString(c_str);
        }

        /// Copy property name at `index` using `allocator`.
        pub fn copyPropertyName(self: Rel, allocator: std.mem.Allocator, index: u64) ![]u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_rel_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.copyCString(allocator, c_str);
        }

        /// Property value at `index` as an owned `Value`.
        pub fn propertyValue(self: Rel, index: u64) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_property_value_at(&self.value.value, index, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }
    };

    pub const RecursiveRel = struct {
        value: *Value,

        /// Get the list of nodes traversed by this recursive relation.
        pub fn nodeList(self: RecursiveRel) !Value {
            return self.value.getRecursiveRelNodeList();
        }

        /// Get the list of relationships traversed by this recursive relation.
        pub fn relList(self: RecursiveRel) !Value {
            return self.value.getRecursiveRelRelList();
        }
    };
};

// Query summary
pub const QuerySummary = struct {
    compiling_time_ms: f64,
    execution_time_ms: f64,
};
