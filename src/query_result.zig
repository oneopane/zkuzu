const std = @import("std");
const bindings = @import("bindings.zig");
const errors = @import("errors.zig");

const c = bindings.c;
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

    pub fn init(result: c.kuzu_query_result, allocator: std.mem.Allocator) QueryResult {
        const arena = allocator.create(ArenaAllocator) catch @panic("arena alloc failed");
        arena.* = ArenaAllocator.init(allocator);
        return .{
            .result = result,
            .allocator = allocator,
            ._arena = arena,
        };
    }

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
    pub fn isSuccess(self: *QueryResult) bool {
        return c.kuzu_query_result_is_success(&self.result);
    }

    // Get error message if query failed
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

    // Get number of columns
    pub fn getColumnCount(self: *QueryResult) u64 {
        return c.kuzu_query_result_get_num_columns(&self.result);
    }

    // Get column name by index
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

    pub fn getColumnIndex(self: *QueryResult, name: []const u8) !?u64 {
        try self.ensureNameIndexCache();
        const map = &self.name_to_index.?;
        return map.get(name);
    }

    // Get column data type by index
    pub fn getColumnDataType(self: *QueryResult, index: u64) !ValueType {
        var dtype: c.kuzu_logical_type = undefined;
        const state = c.kuzu_query_result_get_column_data_type(&self.result, index, &dtype);
        try checkState(state);
        defer c.kuzu_data_type_destroy(&dtype);
        const type_id = c.kuzu_data_type_get_id(&dtype);
        return @as(ValueType, @enumFromInt(type_id));
    }

    // Check if there are more rows
    pub fn hasNext(self: *QueryResult) bool {
        return c.kuzu_query_result_has_next(&self.result);
    }

    // Get next row
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

    // Reset to beginning
    pub fn reset(self: *QueryResult) void {
        if (self.current_row) |row| {
            row.deinit();
            self.current_row = null;
        }
        c.kuzu_query_result_reset_iterator(&self.result);
    }

    // Get query summary
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

    pub fn init(tuple: c.kuzu_flat_tuple, result: *QueryResult, allocator: std.mem.Allocator) Row {
        return .{
            .tuple = tuple,
            .result = result,
            .allocator = allocator,
            .owned_blobs = .{},
            .is_active = true,
        };
    }

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

    // Get value at column index
    pub fn getValue(self: *Row, index: u64) !Value {
        var val: c.kuzu_value = undefined;
        const state = c.kuzu_flat_tuple_get_value(&self.tuple, index, &val);
        try checkState(state);
        var v = Value.fromCValue(val, self.allocator);
        v.owned = true; // values fetched from FlatTuple must be destroyed
        v.owner_row = self;
        return v;
    }

    // Convenience methods for common types
    pub fn getBool(self: *Row, index: u64) !bool {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toBool();
    }

    pub fn getInt(self: *Row, index: u64) !i64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toInt();
    }

    pub fn getFloat(self: *Row, index: u64) !f64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toFloat();
    }

    pub fn getUInt(self: *Row, index: u64) !u64 {
        var val = try self.getValue(index);
        defer val.deinit();
        return val.toUInt();
    }

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

    pub fn copyString(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const s = try self.getString(index);
        return try allocator.dupe(u8, s);
    }

    pub fn getIntByName(self: *Row, name: []const u8) !i64 {
        const idx = (try self.result.getColumnIndex(name)) orelse return Error.InvalidColumn;
        return try self.getInt(idx);
    }

    pub fn getStringByName(self: *Row, name: []const u8) ![]const u8 {
        const idx = (try self.result.getColumnIndex(name)) orelse return Error.InvalidColumn;
        return try self.getString(idx);
    }

    pub fn isNull(self: *Row, index: u64) !bool {
        var val: c.kuzu_value = undefined;
        const state = c.kuzu_flat_tuple_get_value(&self.tuple, index, &val);
        try checkState(state);
        defer c.kuzu_value_destroy(&val);
        return c.kuzu_value_is_null(&val);
    }

    // Extended typed getters
    pub fn getBlob(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toBlob();
    }

    pub fn copyBlob(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const b = try self.getBlob(index);
        return try allocator.dupe(u8, b);
    }

    pub fn getDate(self: *Row, index: u64) !c.kuzu_date_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toDate();
    }

    pub fn getTimestamp(self: *Row, index: u64) !c.kuzu_timestamp_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toTimestamp();
    }

    pub fn getInterval(self: *Row, index: u64) !c.kuzu_interval_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toInterval();
    }

    pub fn getUuid(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toUuid();
    }

    pub fn copyUuid(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const u = try self.getUuid(index);
        return try allocator.dupe(u8, u);
    }

    pub fn getDecimalString(self: *Row, index: u64) ![]const u8 {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toDecimalString();
    }

    pub fn copyDecimalString(self: *Row, allocator: std.mem.Allocator, index: u64) !?[]u8 {
        if (try self.isNull(index)) return null;
        const s = try self.getDecimalString(index);
        return try allocator.dupe(u8, s);
    }

    pub fn getInternalId(self: *Row, index: u64) !c.kuzu_internal_id_t {
        var val = try self.getValue(index);
        defer val.deinit();
        return try val.toInternalId();
    }
};

// Represents result iterator
pub const Rows = struct {
    result: *QueryResult,

    pub fn next(self: *Rows) !?*Row {
        return self.result.next();
    }

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

    pub fn fromCValue(val: c.kuzu_value, allocator: std.mem.Allocator) Value {
        return .{
            .value = val,
            .allocator = allocator,
            .owned = false,
        };
    }

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

    pub fn getType(self: *Value) ValueType {
        var dtype: c.kuzu_logical_type = undefined;
        c.kuzu_value_get_data_type(&self.value, &dtype);
        defer c.kuzu_data_type_destroy(&dtype);
        const type_id = c.kuzu_data_type_get_id(&dtype);
        return @as(ValueType, @enumFromInt(type_id));
    }

    pub fn isNull(self: *Value) bool {
        return c.kuzu_value_is_null(&self.value);
    }

    pub fn toBool(self: *Value) !bool {
        if (self.getType() != .Bool) return Error.TypeMismatch;
        var result: bool = undefined;
        const state = c.kuzu_value_get_bool(&self.value, &result);
        try checkState(state);
        return result;
    }

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

    pub fn toDate(self: *Value) !c.kuzu_date_t {
        if (self.getType() != .Date) return Error.TypeMismatch;
        var d: c.kuzu_date_t = undefined;
        try checkState(c.kuzu_value_get_date(&self.value, &d));
        return d;
    }

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

    pub fn toInterval(self: *Value) !c.kuzu_interval_t {
        if (self.getType() != .Interval) return Error.TypeMismatch;
        var i: c.kuzu_interval_t = undefined;
        try checkState(c.kuzu_value_get_interval(&self.value, &i));
        return i;
    }

    pub fn toUuid(self: *Value) ![]const u8 {
        if (self.getType() != .Uuid) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_uuid(&self.value, &c_str));
        return self.borrowCString(c_str);
    }

    pub fn toDecimalString(self: *Value) ![]const u8 {
        if (self.getType() != .Decimal) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        try checkState(c.kuzu_value_get_decimal_as_string(&self.value, &c_str));
        return self.borrowCString(c_str);
    }

    pub fn toInternalId(self: *Value) !c.kuzu_internal_id_t {
        if (self.getType() != .InternalId) return Error.TypeMismatch;
        var id: c.kuzu_internal_id_t = undefined;
        try checkState(c.kuzu_value_get_internal_id(&self.value, &id));
        return id;
    }

    pub fn toString(self: *Value) ![]const u8 {
        if (self.getType() != .String) return Error.TypeMismatch;
        var c_str: [*c]u8 = undefined;
        const state = c.kuzu_value_get_string(&self.value, &c_str);
        try checkState(state);
        return self.borrowCString(c_str);
    }

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

    pub fn getListLength(self: *Value) !u64 {
        const t = self.getType();
        if (t != .List and t != .Array) return Error.TypeMismatch;
        var size: u64 = 0;
        try checkState(c.kuzu_value_get_list_size(&self.value, &size));
        return size;
    }

    pub fn getListElement(self: *Value, index: u64) !Value {
        const t = self.getType();
        if (t != .List and t != .Array) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_list_element(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

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

    pub fn getMapSize(self: *Value) !u64 {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var size: u64 = 0;
        try checkState(c.kuzu_value_get_map_size(&self.value, &size));
        return size;
    }

    pub fn getMapKey(self: *Value, index: u64) !Value {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_map_key(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    pub fn getMapValue(self: *Value, index: u64) !Value {
        if (self.getType() != .Map) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_map_value(&self.value, index, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    pub fn getRecursiveRelNodeList(self: *Value) !Value {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_recursive_rel_node_list(&self.value, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    pub fn getRecursiveRelRelList(self: *Value) !Value {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        var child_raw: c.kuzu_value = undefined;
        try checkState(c.kuzu_value_get_recursive_rel_rel_list(&self.value, &child_raw));
        return self.makeOwnedChild(child_raw);
    }

    pub fn asNode(self: *Value) !Node {
        if (self.getType() != .Node) return Error.TypeMismatch;
        return Node{ .value = self };
    }

    pub fn asRel(self: *Value) !Rel {
        if (self.getType() != .Rel) return Error.TypeMismatch;
        return Rel{ .value = self };
    }

    pub fn asRecursiveRel(self: *Value) !RecursiveRel {
        if (self.getType() != .RecursiveRel) return Error.TypeMismatch;
        return RecursiveRel{ .value = self };
    }

    pub const Node = struct {
        value: *Value,

        pub fn idValue(self: Node) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn labelValue(self: Node) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_label_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn propertyCount(self: Node) !u64 {
            var size: u64 = 0;
            try checkState(c.kuzu_node_val_get_property_size(&self.value.value, &size));
            return size;
        }

        pub fn propertyName(self: Node, index: u64) ![]const u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_node_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.borrowCString(c_str);
        }

        pub fn copyPropertyName(self: Node, allocator: std.mem.Allocator, index: u64) ![]u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_node_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.copyCString(allocator, c_str);
        }

        pub fn propertyValue(self: Node, index: u64) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_node_val_get_property_value_at(&self.value.value, index, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }
    };

    pub const Rel = struct {
        value: *Value,

        pub fn idValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn srcIdValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_src_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn dstIdValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_dst_id_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn labelValue(self: Rel) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_label_val(&self.value.value, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }

        pub fn propertyCount(self: Rel) !u64 {
            var size: u64 = 0;
            try checkState(c.kuzu_rel_val_get_property_size(&self.value.value, &size));
            return size;
        }

        pub fn propertyName(self: Rel, index: u64) ![]const u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_rel_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.borrowCString(c_str);
        }

        pub fn copyPropertyName(self: Rel, allocator: std.mem.Allocator, index: u64) ![]u8 {
            var c_str: [*c]u8 = undefined;
            try checkState(c.kuzu_rel_val_get_property_name_at(&self.value.value, index, &c_str));
            return self.value.copyCString(allocator, c_str);
        }

        pub fn propertyValue(self: Rel, index: u64) !Value {
            var child_raw: c.kuzu_value = undefined;
            try checkState(c.kuzu_rel_val_get_property_value_at(&self.value.value, index, &child_raw));
            return self.value.makeOwnedChild(child_raw);
        }
    };

    pub const RecursiveRel = struct {
        value: *Value,

        pub fn nodeList(self: RecursiveRel) !Value {
            return self.value.getRecursiveRelNodeList();
        }

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
